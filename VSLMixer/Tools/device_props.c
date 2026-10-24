// Prints CoreAudio latency, safety offset, buffer range and sample rate for
// devices whose name contains the argument; a second argument sets the rate.
// usage: device_props [name-substr] [sample-rate]
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static UInt32 u32(AudioObjectID o, AudioObjectPropertySelector s, AudioObjectPropertyScope sc){
  AudioObjectPropertyAddress a={s,sc,0}; UInt32 v=0,sz=4; AudioObjectGetPropertyData(o,&a,0,0,&sz,&v); return v;}
int main(int argc,char**argv){
  AudioObjectPropertyAddress a={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,0};
  UInt32 sz; AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,0,&sz);
  int n=sz/sizeof(AudioObjectID); AudioObjectID*ids=malloc(sz);
  AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,0,&sz,ids);
  for(int i=0;i<n;i++){
    CFStringRef name; UInt32 s=sizeof(name); AudioObjectPropertyAddress na={kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,0};
    AudioObjectGetPropertyData(ids[i],&na,0,0,&s,&name); char buf[256]; CFStringGetCString(name,buf,256,kCFStringEncodingUTF8);
    if(!strstr(buf, argc>1?argv[1]:"")) continue;
    if(argc>2){ Float64 r=atof(argv[2]); AudioObjectPropertyAddress ra={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,0};
      OSStatus e=AudioObjectSetPropertyData(ids[i],&ra,0,0,sizeof(r),&r); if(e) printf("set rate err %d\n",(int)e); usleep(1500000);}
    Float64 rate; s=8; AudioObjectPropertyAddress ra={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,0};
    AudioObjectGetPropertyData(ids[i],&ra,0,0,&s,&rate);
    AudioValueRange br; s=sizeof(br); AudioObjectPropertyAddress ba={kAudioDevicePropertyBufferFrameSizeRange,kAudioObjectPropertyScopeGlobal,0};
    AudioObjectGetPropertyData(ids[i],&ba,0,0,&s,&br);
    printf("%s  rate=%.0f buf=%u range=%.0f-%.0f\n",buf,rate,u32(ids[i],kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal),br.mMinimum,br.mMaximum);
    AudioObjectPropertyScope sc[2]={kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput};
    for(int k=0;k<2;k++){
      UInt32 st=0; AudioObjectPropertyAddress sa={kAudioDevicePropertyStreams,sc[k],0}; AudioObjectID sid[8]; s=sizeof(sid);
      AudioObjectGetPropertyData(ids[i],&sa,0,0,&s,sid); if(s) st=u32(sid[0],kAudioStreamPropertyLatency,kAudioObjectPropertyScopeGlobal);
      printf("  %s: deviceLatency=%u safetyOffset=%u streamLatency=%u\n",k?"out":"in ",
        u32(ids[i],kAudioDevicePropertyLatency,sc[k]),u32(ids[i],kAudioDevicePropertySafetyOffset,sc[k]),st);
    }
  }
}
