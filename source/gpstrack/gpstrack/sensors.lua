--[[#############################################################################
SENSOR Library: GPS F3X Tracker for Ethos v1.5

Copyright (c) 2024 Axel Barnitzke - original code for OpenTx          MIT License
Copyright (c) 2024 Milan Repik - porting to FrSky Ethos               MIT License

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Change log:
- v1.1: - 
- v1.2: - 
- v1.3: - some small optimizations
- v1.4: - added support for RCGPS-F3x sensor
        - change factors for speed sensors to 1.0 as it is possible to set sensors in Ethos to m/s, deletion of recalculation in sensor.gpsSpeed() function
        - deletion of acceleration sensors and sensor.ax-z() functions as position estimation for AccZ > 5 has been deleted
        - deletion of altitude sensors
        - deletion of date/clock sensors
- v1.5        
################################################################################]]

local sensor = {data = nil, name = 'none', err=''}
local data = {}
-- GPS-Logger3 from SM Modellbau with factory defaults
data.logger3 = {
--    baroAlt  = {name = "Alt", id = 0, factor = 1.0},
--    gpsAlt   = {name = "GAlt", id = 0, factor = 1.0},
    gpsCoord = {name = "GPS", id = 0},  
    gpsSpeed = {name = "GSpd", id = 0, factor = 1.0},       -- SM Logger gives km/h by default, set sensor in Ethos to m/s!
--    gpsDate = {name = "Date", id = 0},
--    gpsDist = {name = "0860", id = 0, factor = 1.0},
--    gpsSats = {name = "0870", id = 0, factor = 1.0},
    gpsSats = {name = "GSats", id = 0, factor = 1.0},       -- There is error in firmware v1.31! Create DIY sensor with Application ID = 0x870 and delete that with 0x860
--    gpsClimb = {name = "0880", id = 0, factor = 1.0},
--    gpsDir = {name = "0890", id = 0},
--    gpsRelDir = {name = "08A0", id = 0},
--    VClimb = {name = "08B0", id = 0, factor = 1.0},
--    Distance = {name = "Fpat", id = 0, factor = 1.0},
--    ax = {name = "AccX", id = 0, factor = 10},             -- unit is 0.1g for firmware v1.31! V1.32 should it correct
--    ay = {name = "AccY", id = 0, factor = 10},
--    az = {name = "AccZ", id = 0, factor = 10}
}
-- Any other GPS Sensor
data.other_gps = {
--    gpsAlt   = {name = "GAlt", id = 0, factor = 1.0},
    gpsCoord = {name = "GPS", id = 0},
    gpsSpeed = {name = "GSpd", id = 0, factor = 1.0},   -- set sensor in Ethos to m/s!
--    gpsDate = {name = "Date", id = 0},
--    ax = {name = "AccX", id = 0, factor = 1.0},
--    ay = {name = "AccY", id = 0, factor = 1.0},
--    az = {name = "AccZ", id = 0, factor = 1.0}
}
-- GPS V2 from FRSky
data.gpsV2 = {
--    gpsAlt   = {name = "GPS Alt", id = 0, factor = 1.0},
    gpsCoord = {name = "GPS", id = 0},
    gpsSpeed = {name = "GPS Speed", id = 0, factor = 1.0},  -- sensor must be configured to give m/s!
--    gpsDate = {name = "GPS Clock", id = 0},
}
-- RCGPS-F3x from Steve
data.rcgpsF3x = {
--    gpsAlt   = {name = "GPS Alt", id = 0, factor = 1.0},
    gpsCoord = {name = "GPS", id = 0},
    gpsSpeed = {name = "GPS Speed", id = 0, factor = 1.0},  -- rcgpsF3x gives knots by default, set sensor in Ethos to m/s!
    -- gpsDate = {name = "Date", id = 0},
    gpsSats = {name = "GPS Sats", id = 0, factor = 1.0},    -- Application ID = 0x5111
    -- gpsHDOP = {name = "GPS HDOP", id = 0}                -- Application ID = 0x5112
}

--[[
function sensor.gpsAlt()
  return sensor.data.gpsAlt.id:value()
end ]]
function sensor.gpsCoord()
--  print ("sensor - sensor.data.gpsCoord.id:value({options=OPTION_LATITUDE})", sensor.data.gpsCoord.id:value({options=OPTION_LATITUDE}))
--  print ("sensor - sensor.data.gpsCoord.id:value({options=OPTION_LONGITUDE})", sensor.data.gpsCoord.id:value({options=OPTION_LONGITUDE}))
  return {lat=sensor.data.gpsCoord.id:value({options=OPTION_LATITUDE}), lon=sensor.data.gpsCoord.id:value({options=OPTION_LONGITUDE})}
end
function sensor.gpsSpeed()
--  print ("sensor - sensor.data.gpsSpeed.id:value()", sensor.data.gpsSpeed.id:value())
  return sensor.data.gpsSpeed.id:value()
end
--[[
function sensor.gpsDate()                                   -- not used at this moment, but it is good to have Ethos clock controlled by GPS clock
--  print ("sensor - sensor.data.gpsDate.id:value()", sensor.data.gpsDate.id:value())  
  return sensor.data.gpsDate.id:value()
end ]]
function sensor.gpsSats()
  if sensor.data.gpsSats then
--      print ("sensor - sensor.data.gpsSats.id:value()", sensor.data.gpsSats.id:value())  
      return sensor.data.gpsSats.id:value()
  end
  return 0
end

function sensor.initializeSensor(data_table)                -- read the field infos for all sensors of the telemetry unit
  sensor.data = data_table
  for name in pairs(sensor.data) do
    local sensorName = sensor.data[name].name
    fieldInfo = system.getSource({category = CATEGORY_TELEMETRY_SENSOR, name = sensorName})
    print("<<"..name.." - "..sensorName..">> ", fieldInfo)
    if not fieldInfo then
      sensor.err = string.format("Sensor '%s' not found", sensorName)
      print(sensor.err)
      return false
    else
      sensor.data[name].id = fieldInfo                      -- store Source IDs of sensors into sensor.data table
    end
  end
  return true
end

function sensor.init(name)                                  -- setup the telemetry unit
  local result = false
  sensor.name = name
  if sensor.name == 'SM Modellbau Logger3' then
    result = sensor.initializeSensor(data.logger3)
  elseif sensor.name == 'FrSky GPS V2' then
    result = sensor.initializeSensor(data.gpsV2)
  elseif sensor.name == 'RCGPS-F3x' then
    result = sensor.initializeSensor(data.rcgpsF3x)    
  elseif sensor.name == 'Any other GPS' then
    result = sensor.initializeSensor(data.other_gps)
  end
  return result
end

return sensor