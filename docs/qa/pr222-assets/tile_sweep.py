import json,glob,math,collections,sys
def brg(a,b):
    la1,lo1,la2,lo2=map(math.radians,(a[0],a[1],b[0],b[1]))
    y=math.sin(lo2-lo1)*math.cos(la2); x=math.cos(la1)*math.sin(la2)-math.sin(la1)*math.cos(la2)*math.cos(lo2-lo1)
    return (math.degrees(math.atan2(y,x))+360)%360
def cd(a,b):
    d=abs(a-b)%360; return min(d,360-d)
def label(side,fwd,heading):
    rev=(fwd+180)%360
    ew=side in "NS"
    line=fwd%180; fna=min(line,180-line)
    off=90-fna if ew else fna
    if off>60: return None
    if abs(fna-45)<=10: return None
    dF,dR=cd(fwd,heading),cd(rev,heading)
    if min(dF,dR)>60: return None
    t=math.radians(fwd if dF<=dR else rev)
    if ew: return "E" if math.sin(t)>0 else "W"
    return "N" if math.cos(t)>0 else "S"
res=collections.Counter(); bad=[]; nilby=collections.Counter(); streets=collections.defaultdict(collections.Counter)
root=sys.argv[1]
for f in glob.glob(root+'/tiles/*.json'):
    d=json.load(open(f))
    if not isinstance(d,list): continue
    for s in d:
        if not isinstance(s,dict) or 'line' not in s: continue
        pts=s['line']
        if len(pts)<2 or s['side'] not in 'NSEW': continue
        for i in range(len(pts)-1):
            fwd=brg(pts[i],pts[i+1])
            lat=pts[i][0]
            manh = 40.70<lat<40.88 and -74.02<pts[i][1]<-73.90
            frame = 29 if manh else 0
            for rv in (0,180):
                h=(fwd+rv)%360
                L=label(s['side'],fwd,h)
                if L is None: nilby['nil']+=1; streets[s['street']]['nil']+=1; continue
                hh=math.radians(h-frame)
                if L in "EW": truth="E" if math.sin(hh)>0 else "W"
                else: truth="N" if math.cos(hh)>0 else "S"
                res['ok' if truth==L else 'bad']+=1
                if truth!=L: bad.append((s['id'],s['side'],round(fwd),L,truth,manh))
                streets[s['street']]['ok' if truth==L else 'bad']+=1
print(res,nilby)
print(len(bad))
c=collections.Counter(b[0].rsplit('_',1)[0] for b in bad); print(c.most_common(15)); print(bad[:10])
for n in ['BROADWAY','5TH AVENUE','2ND AVENUE','EAST HOUSTON STREET','WEST HOUSTON STREET','STANTON STREET','BOWERY','WEST 14TH STREET','EAST 14TH STREET']:
    print(n,dict(streets.get(n,{})))
