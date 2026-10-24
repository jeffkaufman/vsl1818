// 8-channel loopback stress test on one CoreAudio device.
// Plays a distinct continuous sine on outputs 1-8, records inputs 1-8 to a raw file,
// runs a mixer-like DSP load in the IOProc, and logs timestamp discontinuities.
// Needs output N cabled to input N.  The recording buffer is pre-touched and
// locked so page faults don't show up as false dropouts.  Analyze the output
// with analyze_soak.py; see ../README.md for the soak procedure.
// usage: soak <name-substr> <rate> <bufframes> <seconds> <amp> <outfile> [only-chan]
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <sys/mman.h>
#define NC 8
static float *rec; static volatile long pos=0, total; static double sr, amp; static int only=-1;
static volatile int overloads=0, tsjumps=0; static double lastIn=-1, lastOut=-1; static double maxdur=0, maxlate=0, sumdur=0; static long ncb=0; static double tb;
static double evt[256], evd[256], evo[256], evh[256]; static int nevt=0; static uint64_t lastHost=0;
static double freqs[NC]={441.3,553.7,667.1,781.9,893.3,1009.7,1123.1,1237.9};
// simulated mixer state: per channel 4 biquads + compressor, then 8x8 matrix
static double bq[NC][4][5], z[NC][4][2], env[NC], mix[NC][NC]; volatile double sink;
static OSStatus ovl(AudioObjectID o,UInt32 n,const AudioObjectPropertyAddress*a,void*c){overloads++;return 0;}
static float* chan(AudioBufferList*l,int ch,UInt32*stride){
  for(UInt32 b=0;b<l->mNumberBuffers;b++){UInt32 nc=l->mBuffers[b].mNumberChannels;
    if(ch<(int)nc){*stride=nc;return (float*)l->mBuffers[b].mData+ch;} ch-=nc;} return 0;}
static OSStatus io(AudioObjectID d,const AudioTimeStamp*now,const AudioBufferList*in,const AudioTimeStamp*it,
                   AudioBufferList*out,const AudioTimeStamp*ot,void*c){
  uint64_t t0=mach_absolute_time(); double late=(double)((int64_t)(t0-now->mHostTime))*tb;
  UInt32 fr=out->mBuffers[0].mDataByteSize/(4*out->mBuffers[0].mNumberChannels);
  if(lastIn>=0 && it->mSampleTime-lastIn!=fr){ tsjumps++; if(nevt<256){ evt[nevt]=pos/sr; evd[nevt]=it->mSampleTime-lastIn; evo[nevt]=ot->mSampleTime-lastOut; evh[nevt]=(double)(now->mHostTime-lastHost)*tb; nevt++;} }
  lastIn=it->mSampleTime; lastOut=ot->mSampleTime; lastHost=now->mHostTime;
  for(UInt32 b=0;b<out->mNumberBuffers;b++) memset(out->mBuffers[b].mData,0,out->mBuffers[b].mDataByteSize);
  double y[NC];
  for(UInt32 i=0;i<fr;i++){
    long n=pos+i;
    for(int k=0;k<NC;k++){
      UInt32 si,so; float*ip=chan((AudioBufferList*)in,k,&si),*op=chan(out,k,&so);
      if(only<0||only==k) op[i*so]=amp*sin(2*M_PI*freqs[k]*n/sr);
      double x=ip[i*si];
      if(n<total) rec[n*NC+k]=x;
      for(int s=0;s<4;s++){double*c=bq[k][s];double o2=c[0]*x+z[k][s][0];z[k][s][0]=c[1]*x-c[3]*o2+z[k][s][1];z[k][s][1]=c[2]*x-c[4]*o2;x=o2;}
      double a=fabs(x); env[k]+= (a>env[k]?0.01:0.0001)*(a-env[k]);
      double g=env[k]>0.1?pow(env[k]/0.1,-0.75):1.0; y[k]=x*g;
    }
    double acc=0; for(int o=0;o<NC;o++){double s=0;for(int k=0;k<NC;k++)s+=mix[o][k]*y[k];acc+=s;} sink=acc;
  }
  pos+=fr; double dur=(double)(mach_absolute_time()-t0)*tb; ncb++; sumdur+=dur;
  if(dur>maxdur)maxdur=dur; if(late>maxlate)maxlate=late; return 0;}
static AudioObjectID find(const char*want){
  AudioObjectPropertyAddress a={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,0}; UInt32 sz;
  AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,0,&sz); AudioObjectID ids[64];
  AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,0,&sz,ids);
  for(UInt32 i=0;i<sz/4;i++){CFStringRef nm;UInt32 s=sizeof(nm);AudioObjectPropertyAddress na={kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,0};
    AudioObjectGetPropertyData(ids[i],&na,0,0,&s,&nm);char b[256];CFStringGetCString(nm,b,256,kCFStringEncodingUTF8);if(strstr(b,want))return ids[i];}
  return 0;}
int main(int argc,char**argv){
  mach_timebase_info_data_t ti; mach_timebase_info(&ti); tb=1e-3*ti.numer/ti.denom; /* us */
  AudioObjectID d=find(argv[1]); sr=atof(argv[2]); UInt32 bf=atoi(argv[3]); double secs=atof(argv[4]); amp=atof(argv[5]);
  if(argc>7) only=atoi(argv[7]);
  for(int k=0;k<NC;k++){for(int s=0;s<4;s++){bq[k][s][0]=0.9;bq[k][s][1]=0.1;bq[k][s][2]=0.05;bq[k][s][3]=-0.2;bq[k][s][4]=0.1;} for(int o=0;o<NC;o++)mix[o][k]=0.1*(o+k+1);}
  AudioObjectPropertyAddress ra={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,0};
  Float64 cur; UInt32 s=8; AudioObjectGetPropertyData(d,&ra,0,0,&s,&cur);
  if(cur!=sr){ AudioObjectSetPropertyData(d,&ra,0,0,8,&sr); for(int i=0;i<40;i++){usleep(100000);s=8;AudioObjectGetPropertyData(d,&ra,0,0,&s,&cur);if(cur==sr)break;} sleep(1);}
  AudioObjectPropertyAddress ba={kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,0};
  AudioObjectSetPropertyData(d,&ba,0,0,4,&bf); UInt32 got; s=4; AudioObjectGetPropertyData(d,&ba,0,0,&s,&got);
  AudioObjectPropertyAddress oa={kAudioDeviceProcessorOverload,kAudioObjectPropertyScopeGlobal,0};
  AudioObjectAddPropertyListener(d,&oa,ovl,0);
  total=(long)(sr*secs); rec=calloc(total*NC,4);
  memset(rec,1,total*NC*4); memset(rec,0,total*NC*4); if(mlock(rec,total*NC*4)) printf("mlock failed (continuing; memory is pre-touched)\n");
  AudioDeviceIOProcID pid; AudioDeviceCreateIOProcID(d,io,0,&pid); AudioDeviceStart(d,pid);
  long lastpos=-1; int still=0, stalled=0;
  while(pos<total){ usleep(20000); if(pos==lastpos){ if(++still>150){stalled=1;break;} } else still=0; lastpos=pos; }
  if(stalled) printf("STALL: no callbacks for 3s at %.2fs\n", pos/sr);
  AudioDeviceStop(d,pid); AudioDeviceDestroyIOProcID(d,pid);
  FILE*f=fopen(argv[6],"wb"); fwrite(rec,4,total*NC,f); fclose(f);
  printf("rate=%.0f buf=%u (%.0fus) overloads=%d tsjumps=%d  callback avg=%.1fus max=%.1fus  max wake latency=%.1fus\n",sr,got,1e6*got/sr,overloads,tsjumps,sumdur/ncb,maxdur,maxlate);
  if(nevt){printf("  discontinuities at:");for(int i=0;i<nevt;i++)printf("\n   t=%.3fs in_delta=%.0f out_delta=%.0f host_dt=%.0fus",evt[i],evd[i],evo[i],evh[i]);printf("\n");}
}
