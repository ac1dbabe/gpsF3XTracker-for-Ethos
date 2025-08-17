--[[#############################################################################
MAIN: GPS F3X Tracker for Ethos v1.5

Copyright (c) 2024 Axel Barnitzke - original code for OpenTx          MIT License
Copyright (c) 2024 Milan Repik - porting to FrSky Ethos               MIT License               

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Change log:
- v1.1: - the course length considers new global variable global_course_dif, its value is taken from locations[widget.event_place].dif. It keeps value which modifies default course length
        - new global variable global_gps_gpsSats, its value is taken from sensors module and provides for SM-Modelbau GPS-Logger 3 sensor number of visible GPS satellites
        - correction in calculation of timestamp, procedure getETime()
- v1.2: - improved management of fonts
- v1.3: - some optimizations
- v1.4: - implemented logging of flight information
        - enabled flight position estimation/correction
        - implemented management of course length difference during flight
        - deletion of reading of vertical acceleration from sensor for position estimation if acceleration in Z axis > 5g calculated in course.lua
        - deletion of reading of altitude sensor and displaying its value
        - forcing reloadCompetition() when global_correctionFactor changes
        - program speed optimization - screen refresh only each 10th loop, no display of loop rate
- v1.5: - implemented management of the global_correctionFactor during flight
################################################################################]]

-- GLOBAL VARIABLES (don't change)
global_gps_pos = {lat=0.,lon=0.}
global_gps_gpsSats = 0                                      -- number of visible satellites
global_log_file = nil                                       -- hanlder of the log file
global_correctionFactor = 0                                 -- flight position correction constant (0 = not used, 0.5 = max value)
global_logging = false                                      -- switch enabling logging
-- global_home_dir = ...                                    -- defined in setup module
-- global_home_pos = ...                                    -- defined in setup module
-- global_comp_type = ...                                   -- defined in setup module
-- global_comp_types = ...                                  -- defined in setup module
-- global_baseA_left = ...                                  -- defined in setup module, true base A is on left side
-- global_gps_type = ...                                    -- defined in setup module, gives type of GPS sensor
-- global_gps_changed = ...                                 -- defined in setup module, true if type of GPS sensor has changed
-- global_has_changed = ...                                 -- defined in setup module, true if any event parameter has changed
-- global_F3B_locked = ...                                  -- defined in setup module, true when lockGPSHomeSwitch is pressed for "Live" Position & Direction case
-- global_course_dif = ...                                  -- defined in setup module, gives +- difference from the default course length taken from the global_comp_types table

-- VARIABLES
local basePath = '/SCRIPTS/gpstrack/gpstrack/' 
local gpsOK = false
local debug = false
local first_run = true
local rate = 0
local course = nil
local sensor = nil
local screen = nil
local comp = nil
local gps = nil
local length = 0
local LOG_NAME                                              -- variable for name of log file
local runs = 0
local loops = 0
local last_timestamp = 0
local last_loop = 0
local start_event_log = 0
local flightcorfactor_mgmt = nil
local local_correctionFactor

function getETime()                                         -- timestamp in milliseconds for Ethos
  return math.floor(os.clock()*1000)                        -- os.clock needs to multiply by 1000 
end

function mydofile (filename)                                -- module load function
--  print ("filename: " .. filename)
  local f = assert(loadfile(filename))
  return f()
end

local function straight(x, ymin, ymax, b)                   -- simple linear extrapolation
  local offs = b or 0
  local result = math.floor((ymax - ymin) * x / 2048 + offs)
  return result
end

local function getPosition()                                -- debug: fake input (we use this function to emulate GPS input)
  local direction = math.rad(straight(debug_lat:value(),-45,45))
  local position = straight(debug_lon:value(),-60,60)
  if string.find(global_comp_type,"f3b") then
    position = position * 1.5
  end
  global_gps_pos = {lat = direction + math.rad(45.0), lon = position + 60.0}
--  local az = sensor.az()
  return position,direction   
end
-------------------------------------------------------------------------
-- create function
-------------------------------------------------------------------------
local function create()
  return {startSwitchId=nil, debug_lat=nil, debug_lon=nil}
end
-------------------------------------------------------------------------------------------------
-- get one full entry from supported competition types {name, default_mode, course_length, file}
-------------------------------------------------------------------------------------------------
local function getCompEntry(name)
  if type(global_comp_types == 'table') then
    for key,entry in pairs(global_comp_types) do
      if entry.name == name then
        return entry
      end
    end
  end
  return nil
end
-------------------------------------------------------------------------
-- moveHome function - for F3B the home position is base A, course library needs the home in the middle between the bases -> move home in direction of base B by half of course length
-------------------------------------------------------------------------
local function moveHome(half_length)
  if string.find(global_comp_type,"f3b") and (global_home_pos.lat ~= 0) and (global_home_pos.lon ~= 0) then   
    local new_position = gps.getDestination(global_home_pos, half_length, global_home_dir)
    print(string.format("F3B: moved home by %d meter from: %9.6f, %9.6f to: %9.6f, %9.6f",half_length, global_home_pos.lat, global_home_pos.lon, new_position.lat, new_position.lon))
    global_home_pos = new_position
  end
end 
-------------------------------------------------------
-- reloadCompetition function - load a new competition accordingly to new parameters
-------------------------------------------------------
local function reloadCompetition()
  if type(global_comp_types) == 'table' and global_has_changed == true then
    print("<<<< Reload Competition >>>>")
    local save_gpsOK = gpsOK
    global_has_changed = false      
    gpsOK = false                                           -- inactivate background process 
    
    local file_name = 'f3f.luac'                            -- set some useful default values (just in case ...)
    local mode = 'training'
    length = 50
    local entry = getCompEntry(global_comp_type)            -- get competition infomation
    if entry then
      file_name = entry.file                                -- overwrite the defaults with obtained competition infomation
      mode = entry.default_mode  
      length = (entry.course_length + global_course_dif) / 2          -- length is half of course length corrected by course difference taken from locations table
    end
    if comp == nil or comp.name ~= file_name then           -- no competition or different competition required
      if comp ~= nil then
        print("unload: " .. comp.name)
      end
      print("load: " .. file_name)
      comp = nil                                            -- remove old competition class
      collectgarbage("collect")                             -- cleanup memory
      comp = mydofile(basePath..file_name)                  -- load new competition (will crash if file does not exist!)
    end

    screen.resetStack()                                     -- empty the stack if needed
    comp.init(mode, global_baseA_left)                      -- initialize event values
--[[
    if save_gpsOK then                                      -- set ground height
      comp.groundHeight = sensor.gpsAlt() or 0.
    end ]]

    course.init(length, math.rad(global_home_dir), comp)    -- reset course and update competition hooks

    if string.find(global_comp_type,"debug") then           -- any competition type with debug in the name is debugged
      debug = true
    else
      debug = false
    end
    gpsOK = save_gpsOK                                      -- enable background process
  end
end
-------------------------------------------------------------------------
-- startPressed function - checks if switch is activated, triggers on the edge
-------------------------------------------------------------------------
local pressed = false
local function startPressed(switch)
  if switch > 50 and not pressed then
    pressed = true
    return true
  end
  if pressed and switch < -50 then
    pressed = false
  end
  return false
end
-------------------------------------------------------------------------
-- wakeup (periodically called)
-------------------------------------------------------------------------
local function wakeup(widget)  
  if first_run then
    screen.init(true)                                       -- initialize widget screen parameters with extra subscreen with stack
    
    if type(global_comp_types) == 'table' then              -- global variable "global_comp_types" is available
      print("<<< INITIAL RELOAD COMPETITION >>>")
      global_has_changed = true
      reloadCompetition()  
    else
      print("<<< SETUP MISSED >>>")                         -- if global variable "global_comp_types" is not available for some reason, we need some defaults for competition and course
      global_comp_type = 'f3f_trai'
      global_baseA_left = true
      global_home_dir = 9.0
      global_home_pos = { lat=53.550707, lon=9.923472 }
      comp = mydofile(basePath..'f3f.luac')
      comp.init('training', global_baseA_left)              -- initialize event values  
      course.init(10, math.rad(global_home_dir), comp)      -- setup course (debug)
    end
    
    sensor = mydofile(basePath..'sensors.luac')             -- load sensor library, it must be placed here as sensors are not ready when init() is running!
    gpsOK = sensor.init(global_gps_type)                    -- initialize configured GPS sensor
    first_run = false
  end
  
  if global_has_changed then                                -- event parameter(s) has changed -> load a new competition
    reloadCompetition()
  end
  
  if global_gps_changed then                                -- change in GPS sensor -> initialize a new sensor
    global_gps_pos = {lat=0.,lon=0.}
    gpsOK = sensor.init(global_gps_type)
    global_gps_changed = false
  end
  
  if global_F3B_locked then
    moveHome(length)                                        -- move home position for F3B events in direction of base B by half of course length when lockGPSHomeSwitch is pressed for "Live" Position & Direction case
    global_F3B_locked = false
  end  
  
  if debug then                                             -- debug without GPS sensor
    local dist2home,dir2home = getPosition()
    local groundSpeed = 10
--    global_home_dir = 9.0                                   -- do not change, value is taken from locations table
    course.direction = math.rad(global_home_dir)            -- in rad!
    course.update(dist2home, dir2home, groundSpeed)         -- update course
    comp.update()                                           -- update competition
    if global_logging and comp.state > 1 then               -- logging is enabled and event is running -> log details
      global_log_file:write ("comp.state:"..comp.state..string.format(", GPS: %10.7f, %10.7f", global_gps_pos.lat, global_gps_pos.lon)..string.format(", Dist2home: %10.7f, Dir2home: %10.7f, Course distance: %10.7f", dist2home, dir2home, course.Distance),"\n")
    end
  elseif gpsOK then   
    global_gps_pos = sensor.gpsCoord()                      -- read gps position from sensor
    if global_gps_pos.lat and global_gps_pos.lon then
      if comp.state == 1 and flightcorfactor_mgmt then      -- if status = "waiting for start" and source flightcorfactor_mgmt is configured 
        local_correctionFactor = math.abs(math.floor(flightcorfactor_mgmt:value()))
        if local_correctionFactor ~= global_correctionFactor then
          global_correctionFactor = local_correctionFactor  -- change of the correction factor
          system.playNumber(global_correctionFactor/100,0,2)-- announce it
          global_has_changed = true                         -- force reload competition
        end  
      end
      local dist2home = gps.getDistance(global_home_pos, global_gps_pos)
      local dir2home = gps.getBearing(global_home_pos, global_gps_pos)
      local groundSpeed = sensor.gpsSpeed() or 0.           -- read speed from sensor
      course.update(dist2home, dir2home, groundSpeed)       -- update course
      comp.update()                                         -- update competition
      if global_logging and comp.state > 1 then             -- logging is enabled and event is running -> log details
        global_log_file:write (getETime()-start_event_log, ", "..comp.state..string.format(", %10.7f, %10.7f", global_gps_pos.lat, global_gps_pos.lon)..string.format(", %10.7f, %10.7f, %10.7f", dist2home, dir2home, course.Distance)..string.format(", %6.2f, %2d", groundSpeed, global_gps_gpsSats),"\n")
      end  
    else
      print("Main - waiting for lat&lon infomation...")
    end
  end
  loops = loops+1
  if gpsOK or debug then
    if global_gps_pos.lat and global_gps_pos.lon then
      local start = startPressed(widget.startSwitchId:value())                -- check for start event
      if comp and start then
        if global_comp_type == 'f3b_dist' then
          if comp.state ~= 1 and comp.runs > 0 and runs ~= comp.runs then     -- comp finished by hand
            runs = comp.runs                                -- lock update 
            screen.addLaps(comp.runs, comp.lap - 1)         -- add a new lap number to the stack
          end
        end       

        if global_logging then                              -- logging is enabled
          if io.open(LOG_NAME, "r") == nil then             -- check if log file ("YYYY-tLog") exists and create one if not               
            global_log_file = io.open(LOG_NAME, "w")
            global_log_file:close()
          end
          global_log_file = io.open(LOG_NAME, "a")          -- open log file in the append mode
          local mem = {}
          mem = system.getMemoryUsage()
          global_log_file:write (os.date("Start %H-%M-%S")..", Course direction:"..global_home_dir.."°, Course difference:"..global_course_dif.."m, luaRamAvailable:"..mem.luaRamAvailable.."B, Correction factor:"..global_correctionFactor/100,"\n")
          global_log_file:write ("Time since start, Comp.state, GPS lat, GPS lon, Dist2home, Dir2home, Course distance, Speed, Sats","\n")
          start_event_log = getETime()                      -- set the start time for logging
        end
        comp.start()                                        -- reset all values and start the competition
      end  
      if loops % 10 == 0 then                                -- update screen every 10th wakeup run ODLADIT NA OPTIMUM, puvodne loops % 5
        global_gps_gpsSats = sensor.gpsSats() or 0           -- get number of seen GPS satellites (valid only for SM-Modelbau GPS-Logger3 and RCGPS-F3x)
        lcd.invalidate()
      end
    end
  end
end
-------------------------------------------------------------------------
-- paint function
-------------------------------------------------------------------------
local function paint(widget)
  local text  
  lcd.font(screen.font)
  
  if global_comp_type == "f3b_dist" then                    -- set screen title
    text = "F3B: Distance"
  elseif global_comp_type == "f3b_spee" then
    text = "F3B: Speed"
  else
    text = string.format("F3F %s", comp.mode)
  end
  if debug then
    text = text .. " (debug)"
  end
  
  local base = "base A: left"
  if not global_baseA_left then base = "base A: right" end
  text = text .. ", " .. string.format("%s", base)
  screen.title(text)
  screen.title("Runs", true)
  
  screen.text(1, string.format("Comp factor: %3.2f", global_correctionFactor/100))        -- flight correction factor
  text = "Comp: " .. comp.message                           -- status message from comp module (f3f.lua, ...)
  if comp.state == 1 and comp.runs > 0 and runs ~= comp.runs then     -- add results from previous runs
    runs = comp.runs                                        -- lock update
    if global_comp_type == 'f3b_dist' then
      screen.addLaps(runs, comp.lap - 1)                    -- add a new lap number to the stack
    else
      screen.addTime(runs, comp.runtime)                    -- add a new lap number with its time to the stack
      text = text .. ", run: " .. string.format("%2d", runs+1)
    end
  end
  screen.showStack()                                        -- print the contents of the whole stack

  screen.text(2, text)                                      -- status message from comp module (f3f.lua, ...)
  screen.text(3, string.format("Runtime: %5.2fs", comp.runtime/1000.0))         -- event time information
  screen.text(4, "Course: " .. course.message)              -- course state
  screen.text(5, string.format("Spd: %6.2f m/s Dst: %-7.2f m ", course.lastGroundSpeed, course.lastDistance)) -- course information
  if not gpsOK and not debug then
    if string.len(sensor.err) > 0 then                      -- sensor not defined/connected
      screen.text(6, "GPS: " .. sensor.err)
    else
      screen.text(6, "GPS sensor not found: " .. sensor.name)
    end
  else
    if global_gps_pos.lat and global_gps_pos.lon then
        screen.text(6, string.format("GPS: %10.7f, %10.7f", global_gps_pos.lat, global_gps_pos.lon))
    else
        screen.text(6, "GPS: waiting for lat&lon infomation...")
    end    
  end
end
-------------------------------------------------------------------------
-- configure function
-------------------------------------------------------------------------
local function configure(widget)
  line = form.addLine ("")											            -- Help Button field
  form.addButton (line, nil,
    { text="Help",    
      press=function()      
        form.openDialog({
          title="Configuration items", message="1) Start race switch: any 2-position switch, mandatory\n2) Logging: enables logging of event information, use ONLY when needed\n3) Flight correction factor management: Source for setting of the Flight correction factor during flight\n4) Flight correction factor: defines value for the flight position correction, 0 = no correction\n5) Input debug GPS latitude and longitude: analog sources - used to emulate GPS input in debug mode, not mandatory",
          options=TEXT_LEFT,
          buttons={{label="OK", action=function() return true end}},
          closeWhenClickOutside=true })
      end
    })
  
	line = form.addLine ("Start race switch")	                -- Start race Switch field
	form.addSourceField (line, nil, function() return widget.startSwitchId end, function(value) widget.startSwitchId = value end)
  
	line = form.addLine ("Logging")                           -- Controls logging of event information
	form.addBooleanField(line, nil, function() return global_logging end, function(value) global_logging = value end)
  
  line = form.addLine ("Flight correction factor management")	     -- Source for management of Flight correction factor
	form.addSourceField (line, nil, function() return flightcorfactor_mgmt end, function(value) flightcorfactor_mgmt = value end)
  
	line = form.addLine ("Flight correction factor")          -- Defines value for the flight position correction
  local CField = form.addNumberField(line, nil, 0, 50, function() return global_correctionFactor end, function(value) global_correctionFactor = value; global_has_changed = true end)
	CField:decimals(2); CField:step(1)

  line = form.addLine("Input debug GPS latitude")           -- GPS LATITUDE analog Source field - used in getPosition() function to emulate GPS input in debug mode
  form.addSourceField(line, form.getFieldSlots(line)[0], function() return debug_lat end, function(value) debug_lat = value end) 
 
  line = form.addLine("Input debug GPS longitude")          -- GPS LONGITUDE analog Source field - used in getPosition() function to emulate GPS input in debug mode
  form.addSourceField(line, form.getFieldSlots(line)[0], function() return debug_lon end, function(value) debug_lon = value end)
end

local function read(widget)
  widget.startSwitchId = storage.read("startSwitchId")
  debug_lat = storage.read("debug_lat")
  debug_lon = storage.read("debug_lon")
  global_correctionFactor = storage.read("global_correctionFactor")
end

local function write(widget)
  storage.write("startSwitchId", widget.startSwitchId)
  storage.write("debug_lat", debug_lat)
  storage.write("debug_lon", debug_lon)
  storage.write("global_correctionFactor", global_correctionFactor)
end
-------------------------------------------------------------------------
-- init function
-------------------------------------------------------------------------
local function init()
  print("<<< INIT MAIN >>>")
  system.registerWidget({key="Gpstrck", name="GPS F3X Tracker v1.5", create=create, paint=paint, configure=configure, wakeup=wakeup, read=read, write=write})

  local System_ver = system.getVersion()                    -- are we on simulator?
  if System_ver.simulation then
--    print("Simulator detectded")
    if io.open(basePath..'gpslib.lua', "r") ~= nil then     -- if source file(s) is available, compile all libraries, excluding locations.lua
      system.compile(basePath..'gpslib.lua')
      system.compile(basePath..'screen.lua')
      system.compile(basePath..'course.lua')
      system.compile(basePath..'sensors.lua')
      system.compile(basePath..'f3f.lua')
      system.compile(basePath..'f3bdist.lua')
      system.compile(basePath..'f3bsped.lua')
    end  
  end

  gps = mydofile(basePath..'gpslib.luac')                   -- load gps library
  screen = mydofile(basePath..'screen.luac')                -- load screen library
  course = mydofile(basePath..'course.luac')                -- load course library
  
  LOG_NAME = basePath..os.date("%Y%m%d") .. "-Log.txt"      -- prepare name of log file
end

return {init=init}