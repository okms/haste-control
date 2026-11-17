import sys, collections, re
src, out, pad = sys.argv[1], sys.argv[2], int(sys.argv[3],16)
d = open(src,'rb').read(); K=250
for off in range(0,K):
    pass
body=d
key=bytes(collections.Counter(body[p::K]).most_common(1)[0][0]^pad for p in range(K))
dec=bytes(b^key[i%K] for i,b in enumerate(body))
open(out,'wb').write(dec)
s=re.findall(rb'[ -~]{6,}',dec)
print(len(s)); print([x.decode() for x in s[:60]])
