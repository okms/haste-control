import sys,re
txt=open(sys.argv[1],'rb').read()
lines=re.findall(rb':[0-9A-F]{10,}',txt)
mem={}; base=0
for l in lines:
    b=bytes.fromhex(l[1:].decode())
    n,addr,t=b[0],(b[1]<<8)|b[2],b[3]
    if len(b)<n+5: continue
    if (sum(b[:n+5])&0xff)!=0: continue
    data=b[4:4+n]
    if t==4: base=int.from_bytes(data,'big')<<16
    elif t==0:
        for i,x in enumerate(data): mem[base+addr+i]=x
lo,hi=min(mem),max(mem)
print(hex(lo),hex(hi),len(mem))
out=bytearray(b'\xff'*(hi-lo+1))
for a,v in mem.items(): out[a-lo]=v
open(sys.argv[2],'wb').write(out)
