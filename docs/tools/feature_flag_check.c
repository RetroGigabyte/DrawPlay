#include <stdio.h>
#include <stdbool.h>
extern bool _os_feature_enabled_impl(const char*domain,const char*feature);
int main(void){
  printf("backboardd/SupportExternalTouchscreen = %d\n", _os_feature_enabled_impl("backboardd","SupportExternalTouchscreen"));
  printf("WindowServer/DirectTouchEventType     = %d\n", _os_feature_enabled_impl("WindowServer","DirectTouchEventType"));
  printf("WindowServer/Sidecar2                 = %d\n", _os_feature_enabled_impl("WindowServer","Sidecar2"));
  printf("backboardd/NoSuchFlagXYZ              = %d\n", _os_feature_enabled_impl("backboardd","NoSuchFlagXYZ"));
  return 0;}
