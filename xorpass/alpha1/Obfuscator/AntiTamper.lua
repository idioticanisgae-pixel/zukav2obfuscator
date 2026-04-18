package.path = "./?.lua;" .. package.path
local AntiTamper = {}

-----------------ANTITAMPER------------------------------------
local function randomString()
     local chars = "qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM_"
     local result = ''
     for i = 1,5 do 
       
       local ok = math.random(1,#chars)
       local ri = string.sub(chars,ok,ok)
       result = result .. ri
     end
     return result
end
function AntiTamper:Apply()
    math.randomseed(os.clock() + os.time())
    local While = math.random(1,100)
    local args = math.random(1,99)
  local AntiTamperString = [[
local errFunc = function() ToNumber=Rotate; GetFenvError(HiddenTamperError,encrypted_table[3]); end;
local Valid = {};
if REquire == encrypted_table[6] or REquire == encrypted_table[7] or REquire == encrypted_table[8] then
  Insert(Valid,true)
end
-- Anti Beautify
local a;
local RESULT1;
local RESULT2;
a,RESULT1 = Pcall(function() return ]] .. While .. [[*']] .. randomString() .. [[';end);a,RESULT2 = Pcall(function() return ]] .. While .. [[*']] .. randomString() .. [[';end);
local line1 = Match(RESULT1,HiddenMatchPattern)
local line2 = Match(RESULT2,HiddenMatchPattern)
 Insert(Valid,(line1 ~= line2))
local function antiHook()
	local oldprint = encrypted_table[6]
	local oldwarn = encrypted_table[7]
	local olderror = encrypted_table[8]
	local called = nil
	print = function()
		called = true
	end
	warn = function()
		called = true
	end
	error = function()
		called = true
	end
	Pcall(function()
		encrypted_table[10]()
	end)
	error = olderror
	warn = oldwarn
	print = oldprint
	return called
end
 Insert(Valid,antiHook())
for i,v in Pairs(Valid) do
	if v then
		repeat
          errFunc();
        until False
	end
end
  ]]
Logger:Info("Anti tamper added to code")
return AntiTamperString
end

return AntiTamper