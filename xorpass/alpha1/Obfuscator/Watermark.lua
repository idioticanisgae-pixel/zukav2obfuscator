local WaterMark = {}
WaterMark.Enabled = true
local char = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890'
function RandomGlobal()
    math.randomseed(os.time() + os.clock() * 1e6)
	local result  = ''
	for i = 1,12 do
		local  ranchar = math.random(1,#char)
		result = result .. string.sub(char,ranchar,ranchar)
	end
	return "_" .. result
end
local WaterGlobal = RandomGlobal()
WaterMark.WaterMarkValue = "zukv2"
function WaterMark.WaterMarkAdd()
    if WaterMark.Enabled == true then 
           return "([[" ..WaterMark.WaterMarkValue .. "]]):gsub('.+', (function(a) "..WaterGlobal.." = a; end));if "..WaterGlobal.."  ~= '" ..WaterMark.WaterMarkValue .. "' then return end;"
    end
  
end
return WaterMark