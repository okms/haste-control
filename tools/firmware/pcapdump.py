import sys,struct
d=open(sys.argv[1],'rb').read(); i=0
while i+12<=len(d):
    bt,bl=struct.unpack_from('<II',d,i)
    if bl<12: break
    if bt==6:
        cap=struct.unpack_from('<I',d,i+20)[0]; pkt=d[i+28:i+28+cap]
        hl=struct.unpack_from('<H',pkt,0)[0]; pl=pkt[hl:]
        if len(pl)==64:
            ep=pkt[21]; s=pl.hex().rstrip('0')
            if not (sys.argv[2:] and s[:2] not in sys.argv[2:]): print(('OUT ' if ep<0x80 else 'IN  ')+s)
    i+=bl
