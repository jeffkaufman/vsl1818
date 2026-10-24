# Analyzes a soak.c recording.  usage: python3 analyze_soak.py <outfile> <rate>
# For each input channel, least-squares fit the expected sine (any gain/phase) and
# flag 64-sample windows whose residual exceeds -50 dBFS (noise floor is ~-90).
import numpy as np, sys
sr=float(sys.argv[2]); freqs=[441.3,553.7,667.1,781.9,893.3,1009.7,1123.1,1237.9]
r=np.fromfile(sys.argv[1],np.float32).reshape(-1,8); skip=int(sr*0.5); r=r[skip:]
n=np.arange(len(r))+skip; W=64; m=len(r)//W*W
bad_total=0; worst=-200; floors=[]; peaks=[]
for k,f in enumerate(freqs):
    x=r[:m,k].astype(np.float64); s=np.sin(2*np.pi*f*n[:m]/sr); c=np.cos(2*np.pi*f*n[:m]/sr)
    # fit per 1-second segment so slow analog drift doesn't count; glitches still stand out
    res=np.empty(m)
    seg=int(sr)
    for a in range(0,m,seg):
        A=np.stack([s[a:a+seg],c[a:a+seg],np.ones(len(s[a:a+seg]))],1); coef,*_=np.linalg.lstsq(A,x[a:a+seg],rcond=None)
        res[a:a+seg]=x[a:a+seg]-A@coef
    w=20*np.log10(np.sqrt((res.reshape(-1,W)**2).mean(1))+1e-12)
    bad=np.nonzero(w>-50)[0]; bad_total+=len(bad); worst=max(worst,w.max())
    floors.append(np.median(w)); peaks.append(20*np.log10(np.abs(x).max()))
    if len(bad): print(f"  ch{k+1}: {len(bad)} bad windows, first at {(bad[0]*W+skip)/sr:.3f}s")
print(f"  glitch windows={bad_total}  worst residual={worst:.1f} dBFS  noise floor≈{np.median(floors):.1f} dBFS  signal peak≈{np.median(peaks):.1f} dBFS")
