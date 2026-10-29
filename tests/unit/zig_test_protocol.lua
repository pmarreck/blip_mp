local M = dofile(arg[1])
local function u32(n)
	return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)
end
local function frame(tag,body) return u32(tag)..u32(#body)..body end
local version = frame(0,"0.16.0")
local metadata = frame(3,u32(5)..u32(2)..u32(1)..u32(3)..u32(0)..u32(0).."\0a\0b\0")
local function result(index,flags) return frame(5,"")..frame(4,u32(index)..u32(flags or 0)..u32(0)) end
local good = version..metadata
local md = M.metadata(good)
assert(md.names[1]=="a" and md.names[2]=="b" and #md.names==2)
assert(M.requests(2,2,0)==frame(4,"")..frame(5,u32(0))..frame(0,""))
assert(M.requests(2,2,1)==frame(4,"")..frame(5,u32(1))..frame(0,""))
assert(M.check(md,{good..result(0),good..result(1)})==2)
local bad = {
	{good..result(0),good},
	{good..result(0)..result(0),good..result(1)},
	{good..result(1),good..result(0)},
	{good..result(0,1),good..result(1)},
	{good..result(0,2),good..result(1)},
	{good..result(0,4),good..result(1)},
	{good..result(0,8),good..result(1)},
	{good..frame(5,"")..frame(4,u32(0)..u32(0)..u32(2)),good..result(1)},
	{good..frame(4,u32(0)..u32(0)..u32(0)),good..result(1)},
	{good..result(0):sub(1,-2),good..result(1)},
	{frame(0,"0.17.0")..metadata..result(0),good..result(1)},
	{good..result(0)..frame(99,""),good..result(1)},
	{good..result(0),(good:gsub("b\0","c\0"))..result(1)},
}
for i,outputs in ipairs(bad) do assert(not pcall(M.check,md,outputs),"accepted invalid result set "..i) end
for _,input in ipairs({"",good:sub(1,-2),frame(0,"0.17.0")..metadata,good..metadata}) do
	assert(not pcall(M.metadata,input),"accepted invalid metadata")
end
for n=0,128 do for shards=1,8 do
	local outputs={}
	local selected={}
	local names={}; for i=1,n do names[i]="case"..i end
	local strings="\0"; local offsets=""; local panics=""
	for _,name in ipairs(names) do offsets=offsets..u32(#strings); strings=strings..name.."\0"; panics=panics..u32(0) end
	local prefix=version..frame(3,u32(#strings)..u32(n)..offsets..panics..strings)
	for shard=0,shards-1 do
		local requests=M.requests(n,shards,shard)
		assert(requests:sub(1,8)==frame(4,"") and requests:sub(-8)==frame(0,""))
		assert((#requests-16)%12==0)
		for pos=9,#requests-8,12 do
			assert(requests:sub(pos,pos+7)==u32(5)..u32(4))
			local a,b,c,d=requests:byte(pos+8,pos+11)
			local index=a+b*256+c*65536+d*16777216
			assert(index<n and index%shards==shard and not selected[index],"invalid request partition")
			selected[index]=true
		end
		local body=prefix
		for index=shard,n-1,shards do body=body..result(index) end
		outputs[#outputs+1]=body
	end
	for index=0,n-1 do assert(selected[index],"missing request") end
	assert(M.check(M.metadata(prefix),outputs)==n)
end end
print("protocol controls passed")
