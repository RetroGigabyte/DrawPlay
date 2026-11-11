#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <objc/message.h>
int main(void){
  @autoreleasepool {
    const char*fw[]={"BackBoardHIDTouchEventProcessor","BackBoardHIDEventFoundation","BackBoardServices","UniversalHIDKit"};
    for(int i=0;i<4;i++){ char p[512]; snprintf(p,sizeof p,"/System/Library/PrivateFrameworks/%s.framework/%s",fw[i],fw[i]); dlopen(p,RTLD_NOW);}
    Class c=objc_getClass("BKHIDDirectTouchEventProcessor");
    id d=((id(*)(Class,SEL))objc_msgSend)(c,sel_registerName("digitizerMatchingDictionaries"));
    NSLog(@"digitizerMatchingDictionaries =\n%@",d);
    unsigned n; Class*all=objc_copyClassList(&n);
    for(unsigned i=0;i<n;i++){ const char*nm=class_getName(all[i]); if(strcasestr(nm,"chamois")||strcasestr(nm,"AccessoryTouch")) printf("class %s\n",nm);}
  }
  return 0;}
