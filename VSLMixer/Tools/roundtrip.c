// Native CoreAudio round-trip latency test: out CH -> in CH on one device.
// Plays a chirp and finds it in the recording by cross-correlation.
// usage: roundtrip <name-substr> <rate> <bufframes> <channel(0-based)>
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#define N (1<<20)
static float play[N], rec[N]; static volatile long pos=0, total; static int CH; static volatile int overloads=0;
static OSStatus ovl(AudioObjectID o,UInt32 n,const AudioObjectPropertyAddress*a,void*c){overloads++;return 0;}
static float* chan(AudioBufferList*l,int ch,UInt32*stride){
  for(UInt32 b=0;b<l->mNumberBuffers;b++){UInt32 nc=l->mBuffers[b].mNumberChannels;
    if(ch<(int)nc){*stride=nc;return (float*)l->mBuffers[b].mData+ch;} ch-=nc;} return 0;}
static OSStatus io(AudioObjectID d,const AudioTimeStamp*now,const AudioBufferList*in,const AudioTimeStamp*it,
                   AudioBufferList*out,const AudioTimeStamp*ot,void*c){
  UInt32 fr=out->mBuffers[0].mDataByteSize/(4*out->mBuffers[0].mNumberChannels), si,so;
  for(UInt32 b=0;b<out->mNumberBuffers;b++) memset(out->mBuffers[b].mData,0,out->mBuffers[b].mDataByteSize);
  float*ip=chan((AudioBufferList*)in,CH,&si),*op=chan(out,CH,&so);
  for(UInt32 i=0;i<fr && pos+i<total;i++){ op[i*so]=play[pos+i]; rec[pos+i]=ip[i*si]; }
  pos+=fr; return 0;}
static AudioObjectID find(const char*want){
  AudioObjectPropertyAddress a={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,0}; UInt32 sz;
  AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,0,&sz); AudioObjectID ids[64];
  AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,0,&sz,ids);
  for(UInt32 i=0;i<sz/4;i++){CFStringRef nm;UInt32 s=sizeof(nm);AudioObjectPropertyAddress na={kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,0};
    AudioObjectGetPropertyData(ids[i],&na,0,0,&s,&nm);char b[256];CFStringGetCString(nm,b,256,kCFStringEncodingUTF8);if(strstr(b,want))return ids[i];}
  return 0;}
int main(int argc,char**argv){
  AudioObjectID d=find(argv[1]); Float64 sr=atof(argv[2]); UInt32 bf=atoi(argv[3]); CH=atoi(argv[4]);
  AudioObjectPropertyAddress ra={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,0};
  Float64 cur; UInt32 s=8; AudioObjectGetPropertyData(d,&ra,0,0,&s,&cur);
  if(cur!=sr){ AudioObjectSetPropertyData(d,&ra,0,0,8,&sr); for(int i=0;i<40;i++){usleep(100000);s=8;AudioObjectGetPropertyData(d,&ra,0,0,&s,&cur);if(cur==sr)break;} sleep(1);}
  AudioObjectPropertyAddress ba={kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,0};
  AudioObjectSetPropertyData(d,&ba,0,0,4,&bf); UInt32 got; s=4; AudioObjectGetPropertyData(d,&ba,0,0,&s,&got);
  AudioObjectPropertyAddress oa={kAudioDeviceProcessorOverload,kAudioObjectPropertyScopeGlobal,0};
  AudioObjectAddPropertyListener(d,&oa,ovl,0);
  total=(long)(sr*1.5); int start=(int)(sr*0.5), L=(int)(sr*0.05);
  for(int i=0;i<L;i++){double t=i/sr; play[start+i]=0.2*sin(2*M_PI*(500*t+75000*t*t))*0.5*(1-cos(2*M_PI*i/(L-1)));}
  AudioDeviceIOProcID pid; AudioDeviceCreateIOProcID(d,io,0,&pid); AudioDeviceStart(d,pid);
  while(pos<total) usleep(20000); AudioDeviceStop(d,pid); AudioDeviceDestroyIOProcID(d,pid);
  double best=0,e=0; int bd=0; for(int i=0;i<L;i++)e+=play[start+i]*play[start+i];
  for(int dl=0; dl<total-start-L; dl++){double c=0; for(int i=0;i<L;i++)c+=rec[start+dl+i]*play[start+i]; if(fabs(c)>best){best=fabs(c);bd=dl;}}
  printf("%6.0f %5u %7d %6.2f  %5.2f %4d\n",sr,got,bd,1000.0*bd/sr,best/e,overloads);
}
