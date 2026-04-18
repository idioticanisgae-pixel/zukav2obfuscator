
local String = {}
package.path = "./?.lua;" .. package.path

math.randomseed(os.time() + os.clock() * 1e6)
key = math.random(1,255)
key2 = math.random(1,6)
param = math.random(1,1000)
function GetPsewdo()
	local t1 = param * 2
	local t2 = t1 + 41
	local t3 = t1 + t2
	return {t1,t2,t3}
end
local function encrypt(str)
	local result = ""
	for i =1,#str do
		local char = string.sub(str,i,i)
		local byte = string.byte(char)
		local keys = GetPsewdo()
		local encrypted_byte = (byte + key + keys[1]+ keys[2]+ keys[3] + (i + key2)) % 256
		result = result .. string.char(encrypted_byte)
	end
	return result
end
local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function compress(str)
	local result = ""
	for i = 1, #str do
		local byte = string.byte(str, i)
		local c1 = math.floor(byte / 4) + 1
		local c2 = (byte % 4) * 16 + 1
		result = result ..chars:sub(c1, c1) ..chars:sub(c2, c2)
	end
	return result
end
local Logger = require("logger")
function String:Encrypt(sourse)
    local encrypted = encrypt(sourse);
    local out = compress(encrypted)
	return out
end

function String.AddDecodeCode(encrypted)
	     local CF = math.random(10,255)
         return [[
local decropress,decrypt,ARR,key1,key2,temp,key3,key4,GetPsewdo,key5,chars = nil,nil,nil,]] .. CF * 3.2 ..[[,]] .. CF * 5 ..[[,nil,]] .. CF * 4.4 ..[[,]] .. CF * 2.3 ..[[,nil,]] .. CF * 4.1 ..[[,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
if key1 then
if key2 then
if key3 then
if key4 then
local GlobalTable = {
  []] .. CF * 3.2 ..[[] = function()
	  decropress = function(str)
    	local result = ""
	for i = 1, #str, 2 do
		local c1 = Find(chars, Sub(str,i, i)) - 1
        local c2 = Find(chars, Sub(str,i + 1, i + 1)) - 1
		local byte = c1 * 4 + Floor(c2 / 16)
		result = result .. Char(byte)
	end
	return result
     end;
  end,
    []] .. CF * 5 ..[[] = function()
	 decrypt = function(str)
	local result = {}
	for i =1,#str do
		local char = Sub(str,i,i)
		local byte = Byte(char)
		local keys = GetPsewdo()
		local encrypted_byte = (byte -  ]]..key..[[ - keys[1]-keys[2]- keys[3] - (i + ]]..key2..[[)) % 256
		result[i] = Char(encrypted_byte)
	end
	return result
end
  end,
     []] .. CF * 4.4 ..[[] = function()
	if decropress then 
		if decrypt then
     temp = decropress(']] .. encrypted .. [[');
		end;
	end;
  end,
  []] .. CF * 2.3 ..[[] = function()
	if decrypt then
	if decropress then 
     ARR = decrypt(temp);
	 end;
	end;
  end,
  []] .. CF * 4.1 ..[[] = function()
     GetPsewdo = function()
		local t1 = ]] ..param.. [[ * 2
	    local t2 = t1 + 41
	    local t3 = t1 + t2
	    return {t1,t2,t3}
	 end
  end,
};
if key1 then
GlobalTable[key5]();
if key2 then
GlobalTable[key1]();
if key3 then
GlobalTable[key2]();
if key4 then
if key5 then
GlobalTable[key3]();
end;
end;
end;
GlobalTable[key4]();
end;
end;
end;
end;
end;
end;
]]
end
return String