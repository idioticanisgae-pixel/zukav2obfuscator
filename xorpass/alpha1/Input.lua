return (function(...) (function() return('when in doubt whip it out') end)();
local __warn=(function()
    local _ok,_f=pcall(function()return warn end)
    return(_ok and type(_f)=="function")and _f or print
end)()
local Sub,Byte,Char,Find,Floor,Pairs,Insert,Pcall,ToNumber=string.sub,string.byte,string.char,string.find,math.floor,pairs,table.insert,pcall,tonumber;
local encrypted_table={[6]=print,[7]=__warn,[8]=error,[10]=function()end};
local decropress,decrypt,ARR,key1,key2,temp,key3,key4,GetPsewdo,key5,chars = nil,nil,nil,764.8,1195,nil,1051.6,549.7,nil,979.9,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
if key1 then
if key2 then
if key3 then
if key4 then
local GlobalTable = {
  [764.8] = function()
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
    [1195] = function()
	 decrypt = function(str)
	local result = {}
	for i =1,#str do
		local char = Sub(str,i,i)
		local byte = Byte(char)
		local keys = GetPsewdo()
		local encrypted_byte = (byte -  49 - keys[1]-keys[2]- keys[3] - (i + 5)) % 256
		result[i] = Char(encrypted_byte)
	end
	return result
end
  end,
     [1051.6] = function()
	if decropress then 
		if decrypt then
     temp = decropress('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');
		end;
	end;
  end,
  [549.7] = function()
	if decrypt then
	if decropress then 
     ARR = decrypt(temp);
	 end;
	end;
  end,
  [979.9] = function()
     GetPsewdo = function()
		local t1 = 906 * 2
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
if ARR then
    local _src=table.concat(ARR)
    local _fn,_err=(loadstring or load)(_src)
    if _fn then _fn() else error("uwu cutie error: "..tostring(_err)) end
end
 end)(...)