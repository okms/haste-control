import sys, collections
d = open(sys.argv[1],'rb').read()
body = d[16:]
best=[]
for k in range(1,600):
    score=0
    for p in range(k):
        c=collections.Counter(body[p::k]); score+=c.most_common(1)[0][1]
    best.append((score/len(body),k))
best.sort(reverse=True)
print(best[:10])
# 16-byte chunk repetition
c=collections.Counter(body[i:i+16] for i in range(0,len(body)-16,16))
print(c.most_common(5))
print(len(d), d[:16].hex())
