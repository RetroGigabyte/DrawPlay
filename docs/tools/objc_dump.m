#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
static void dumpClass(Class c){
  printf("\n### %s : %s\n", class_getName(c), class_getSuperclass(c)?class_getName(class_getSuperclass(c)):"-");
  unsigned n; Ivar *iv=class_copyIvarList(c,&n); for(unsigned i=0;i<n;i++) printf("  ivar %s %s\n",ivar_getName(iv[i]),ivar_getTypeEncoding(iv[i])); free(iv);
  for(int meta=0;meta<2;meta++){ Class k=meta?object_getClass(c):c; Method*m=class_copyMethodList(k,&n);
    for(unsigned i=0;i<n;i++) printf("  %c %s\n",meta?'+':'-',sel_getName(method_getName(m[i]))); free(m);}
}
int main(int argc,char**argv){
  const char*fw[]={"BackBoardHIDTouchEventProcessor","BackBoardHIDEventFoundation","BackBoardServices","UniversalHIDKit"};
  for(int i=0;i<4;i++){ char p[512]; snprintf(p,sizeof p,"/System/Library/PrivateFrameworks/%s.framework/%s",fw[i],fw[i]);
    void*h=dlopen(p,RTLD_NOW); printf("dlopen %s: %s\n",fw[i],h?"ok":dlerror()); }
  for(int a=1;a<argc;a++){ Class c=objc_getClass(argv[a]); if(c) dumpClass(c); else printf("no class %s\n",argv[a]); }
  if(argc==1){ unsigned n; Class*all=objc_copyClassList(&n); for(unsigned i=0;i<n;i++){ const char*nm=class_getName(all[i]); if(strstr(nm,"DirectTouch")||strstr(nm,"BKTouch")||strstr(nm,"BKDigitizer")||strstr(nm,"TouchScreen")) printf("class %s (%s)\n",nm,class_getImageName(all[i])); } }
  return 0;}
