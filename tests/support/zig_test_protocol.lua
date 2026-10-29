-- Zig 0.16.0's little-endian test-server protocol. Reject unknown messages and
-- incomplete result sets; never infer success from a worker's exit status alone.
local M = {}
local function u32(data,p)
	assert(p>=1 and p+3<=#data,"truncated integer")
	local a,b,c,d=data:byte(p,p+3)
	return a+256*b+65536*c+16777216*d
end
local function pack(n)
	assert(n>=0 and n<=4294967295 and n==math.floor(n),"invalid integer")
	return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)
end
local function frame(tag,body) return pack(tag)..pack(#body)..body end
local function frames(data)
	local out={}; local p=1
	while p<=#data do
		local tag,len=u32(data,p),u32(data,p+4)
		p=p+8; assert(len<=#data-p+1,"truncated frame")
		out[#out+1]={tag=tag,body=data:sub(p,p+len-1)}; p=p+len
	end
	return out
end
local function metadata(fs)
	assert(fs[1] and fs[1].tag==0 and fs[1].body=="0.16.0","unexpected compiler")
	assert(fs[2] and fs[2].tag==3,"missing metadata")
	local body=fs[2].body
	local string_len,n=u32(body,1),u32(body,5)
	assert(#body==8+8*n+string_len,"invalid metadata length")
	local strings=body:sub(9+8*n)
	assert(strings:sub(1,1)=="\0","missing null string")
	local names,seen={},{}
	for i=0,n-1 do
		local offset=u32(body,9+4*i)
		assert(u32(body,9+4*n+4*i)==0,"expected-panic tests unsupported")
		assert(offset>0 and offset<#strings,"invalid name offset")
		local last=assert(strings:find("\0",offset+1,true),"unterminated name")
		local name=strings:sub(offset+1,last-1)
		assert(#name>0 and not seen[name],"empty or duplicate test name")
		seen[name]=true; names[#names+1]=name
	end
	return {names=names,body=body}
end
function M.metadata(data)
	local fs=frames(data); assert(#fs==2,"unexpected metadata frames")
	return metadata(fs)
end
function M.requests(n,shards,shard)
	pack(n); pack(shards); pack(shard)
	assert(shards>0 and shard<shards,"invalid shard")
	local out={frame(4,"")}
	for index=shard,n-1,shards do out[#out+1]=frame(5,pack(index)) end
	out[#out+1]=frame(0,"")
	return table.concat(out)
end
function M.check(md,outputs)
	assert(#outputs>0,"missing workers")
	local count=0
	for worker,data in ipairs(outputs) do
		local fs=frames(data); local got=metadata(fs)
		assert(got.body==md.body,"worker inventory mismatch")
		local p=3
		for index=worker-1,#md.names-1,#outputs do
			assert(fs[p] and fs[p].tag==5 and #fs[p].body==0,"missing start")
			local result=fs[p+1]
			assert(result and result.tag==4 and #result.body==12,"missing result")
			assert(u32(result.body,1)==index,"wrong or duplicate index")
			assert(u32(result.body,5)==0 and u32(result.body,9)==0,"failed, skipped, logged, fuzzed or leaking test: "..md.names[index+1])
			count=count+1; p=p+2
		end
		assert(p==#fs+1,"extra result frames")
	end
	assert(count==#md.names,"incomplete test set")
	return count
end
return M
