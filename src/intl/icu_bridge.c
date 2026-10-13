#include <unicode/ucal.h>
#include <unicode/udat.h>
#include <unicode/udatpg.h>
#include <unicode/uloc.h>
#include <unicode/ustring.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
typedef struct { int32_t year, month, month_code, leap_month, day, era, era_year, day_of_year, days_in_month, days_in_year, months_in_year, leap_year; } ZCalendarInfo;
static const UChar UTC_ZONE[] = { 'U','T','C',0 };
static UCalendar *open_calendar(const char *id, UErrorCode *status) {
 char locale[128]; snprintf(locale,sizeof locale,"en_US@calendar=%s", strcmp(id,"ethioaa")==0?"ethiopic-amete-alem":id);
 UCalendar *cal=ucal_open(UTC_ZONE,3,locale,UCAL_DEFAULT,status);
 if(cal) { ucal_setAttribute(cal,UCAL_LENIENT,0); if(strcmp(id,"gregory")==0) ucal_setGregorianChange(cal,-8.64e15,status); }
 return cal;
}
static int32_t temporal_year(const char *id,UCalendar *cal,UErrorCode *status) {
 int32_t ext=ucal_get(cal,UCAL_EXTENDED_YEAR,status);
 if(strcmp(id,"chinese")==0) return ext-(U_ICU_VERSION_MAJOR_NUM<78?2637:0);
 if(strcmp(id,"dangi")==0) return ext-(U_ICU_VERSION_MAJOR_NUM<78?2333:0);
 if(strcmp(id,"buddhist")==0) return ext+543;
 if(strcmp(id,"roc")==0) return ext-1911;
 if(strcmp(id,"ethioaa")==0) return ext+(U_ICU_VERSION_MAJOR_NUM<78?5500:0);
 return ext;
}
static void set_year(const char *id,UCalendar *cal,int32_t year) {
 if(strcmp(id,"chinese")==0) year+=(U_ICU_VERSION_MAJOR_NUM<78?2637:0); else if(strcmp(id,"dangi")==0) year+=(U_ICU_VERSION_MAJOR_NUM<78?2333:0); else if(strcmp(id,"buddhist")==0) year-=543; else if(strcmp(id,"roc")==0) year+=1911; else if(strcmp(id,"ethioaa")==0) year-=(U_ICU_VERSION_MAJOR_NUM<78?5500:0);
 ucal_set(cal,UCAL_EXTENDED_YEAR,year);
}
static int ordinal_month(UCalendar *cal,UErrorCode *status,int *months,int *days) {
 UCalendar *cursor=ucal_clone(cal,status); if(!cursor) return 0;
 const int year=ucal_get(cal,UCAL_EXTENDED_YEAR,status), month=ucal_get(cal,UCAL_MONTH,status), leap=ucal_get(cal,UCAL_IS_LEAP_MONTH,status);
 ucal_set(cursor,UCAL_DATE,1); ucal_set(cursor,UCAL_MONTH,0); ucal_set(cursor,UCAL_IS_LEAP_MONTH,0);
 int count=0,ordinal=0,total=0;
 do { count++; if(ucal_get(cursor,UCAL_MONTH,status)==month&&ucal_get(cursor,UCAL_IS_LEAP_MONTH,status)==leap) ordinal=count;
 total+=ucal_getLimit(cursor,UCAL_DATE,UCAL_ACTUAL_MAXIMUM,status); ucal_add(cursor,UCAL_MONTH,1,status);
 } while(U_SUCCESS(*status)&&ucal_get(cursor,UCAL_EXTENDED_YEAR,status)==year&&count<14);
 ucal_close(cursor); *months=count; *days=total; return ordinal;
}
int z_calendar_info(const char *id,int64_t epoch_day,ZCalendarInfo *out) {
 UErrorCode status=U_ZERO_ERROR; UCalendar *cal=open_calendar(id,&status); if(U_FAILURE(status)||!cal) return status==U_MEMORY_ALLOCATION_ERROR?2:1;
 ucal_setMillis(cal,(double)epoch_day*86400000.,&status);
 out->year=temporal_year(id,cal,&status); out->day=ucal_get(cal,UCAL_DATE,&status); out->era=ucal_get(cal,UCAL_ERA,&status); out->era_year=ucal_get(cal,UCAL_YEAR,&status); out->day_of_year=ucal_get(cal,UCAL_DAY_OF_YEAR,&status); out->days_in_month=ucal_getLimit(cal,UCAL_DATE,UCAL_ACTUAL_MAXIMUM,&status);
 const int raw=ucal_get(cal,UCAL_MONTH,&status); out->leap_month=ucal_get(cal,UCAL_IS_LEAP_MONTH,&status); out->month_code=raw+1;
 if(strcmp(id,"hebrew")==0) { if(raw==5) {out->month_code=5;out->leap_month=1;} else if(raw>=6) out->month_code=raw; }
 out->month=ordinal_month(cal,&status,&out->months_in_year,&out->days_in_year);
 out->leap_year=(strcmp(id,"hebrew")==0||strcmp(id,"chinese")==0||strcmp(id,"dangi")==0)?out->months_in_year==13:(strncmp(id,"islamic",7)==0?out->days_in_year==355:out->days_in_year==366);
 ucal_close(cal); return U_SUCCESS(status)?0:(status==U_MEMORY_ALLOCATION_ERROR?2:1);
}
int z_calendar_from_fields(const char *id,int year,int month,int day,int code,int leap,int constrain,int64_t *epoch_day) {
 UErrorCode status=U_ZERO_ERROR; UCalendar *cal=open_calendar(id,&status); if(U_FAILURE(status)||!cal) return status==U_MEMORY_ALLOCATION_ERROR?2:1;
 ucal_clear(cal); set_year(id,cal,year); ucal_set(cal,UCAL_MONTH,0); ucal_set(cal,UCAL_DATE,1);
 if(code) { int raw=code-1; if(strcmp(id,"hebrew")==0) raw=leap?5:(code>=6?code:code-1); ucal_set(cal,UCAL_MONTH,raw); ucal_set(cal,UCAL_IS_LEAP_MONTH,leap); }
 else {
  if(month<1) {ucal_close(cal);return 1;} int i=1;
  while(i<month&&U_SUCCESS(status)) { UDate prev=ucal_getMillis(cal,&status);ucal_add(cal,UCAL_MONTH,1,&status);if(temporal_year(id,cal,&status)!=year) {ucal_setMillis(cal,prev,&status);if(!constrain)status=U_ILLEGAL_ARGUMENT_ERROR;break;}i++; }
 }
 if(day<1) status=U_ILLEGAL_ARGUMENT_ERROR;
 int max=ucal_getLimit(cal,UCAL_DATE,UCAL_ACTUAL_MAXIMUM,&status); if(constrain&&day>max)day=max;ucal_set(cal,UCAL_DATE,day);
 const double ms=ucal_getMillis(cal,&status); if(U_SUCCESS(status)&&temporal_year(id,cal,&status)!=year)status=U_ILLEGAL_ARGUMENT_ERROR;
 if(code&&U_SUCCESS(status)) { const int raw=ucal_get(cal,UCAL_MONTH,&status), actual_leap=ucal_get(cal,UCAL_IS_LEAP_MONTH,&status);
 int actual_code=raw+1;if(strcmp(id,"hebrew")==0)actual_code=raw==5?5:(raw>=6?raw:raw+1);
 const int requested_leap=leap;const int actual_is_leap=strcmp(id,"hebrew")==0?raw==5:actual_leap;
 if(actual_code!=code||actual_is_leap!=requested_leap)status=U_ILLEGAL_ARGUMENT_ERROR; }
 if(U_SUCCESS(status))*epoch_day=(int64_t)floor(ms/86400000.);
 ucal_close(cal); return U_SUCCESS(status)?0:(status==U_MEMORY_ALLOCATION_ERROR?2:1);
}
int z_calendar_add(const char *id,int64_t origin,int years,int months,int constrain,int64_t *epoch_day) {
 ZCalendarInfo info;if(z_calendar_info(id,origin,&info))return 1;
 int64_t mid=origin; if(years&&z_calendar_from_fields(id,info.year+years,0,info.day,info.month_code,info.leap_month,constrain,&mid)) {
  if(!constrain||!info.leap_month||z_calendar_from_fields(id,info.year+years,0,info.day,(strcmp(id,"hebrew")==0?6:info.month_code),0,constrain,&mid))return 1;
 }
 UErrorCode status=U_ZERO_ERROR;UCalendar *cal=open_calendar(id,&status);if(!cal)return 2;
 ucal_setMillis(cal,(double)mid*86400000.,&status);const int day=ucal_get(cal,UCAL_DATE,&status);(void)ucal_get(cal,UCAL_MONTH,&status);(void)ucal_get(cal,UCAL_IS_LEAP_MONTH,&status);ucal_set(cal,UCAL_DATE,1);ucal_add(cal,UCAL_MONTH,months,&status);(void)ucal_getMillis(cal,&status);(void)ucal_get(cal,UCAL_MONTH,&status);(void)ucal_get(cal,UCAL_IS_LEAP_MONTH,&status);
 const int max=ucal_getLimit(cal,UCAL_DATE,UCAL_ACTUAL_MAXIMUM,&status);if(day>max&&!constrain)status=U_ILLEGAL_ARGUMENT_ERROR;
 ucal_set(cal,UCAL_DATE,day>max?max:day);const double ms=ucal_getMillis(cal,&status);if(U_SUCCESS(status))*epoch_day=(int64_t)floor(ms/86400000.);ucal_close(cal);return U_SUCCESS(status)?0:1;
}
int z_locale_date(const char *locale,const char *calendar,const char *zone,const char *pattern,int date_style,int time_style,double millis,char *out,int capacity) {
 UErrorCode status=U_ZERO_ERROR;UChar zone16[256],pattern16[128],result[1024];int32_t zlen=0,plen=0;
 u_strFromUTF8(zone16,256,&zlen,zone,-1,&status);u_strFromUTF8(pattern16,128,&plen,pattern,-1,&status);
 char base[256];int32_t parsed=0;uloc_forLanguageTag(locale,base,sizeof base,&parsed,&status);if(U_FAILURE(status)||parsed!=(int32_t)strlen(locale))return -1;
 char loc[256];memcpy(loc,base,strlen(base)+1);uloc_setKeywordValue("calendar",strcmp(calendar,"ethioaa")==0?"ethiopic-amete-alem":calendar,loc,sizeof loc,&status);
 if(date_style<0&&time_style<0){UDateTimePatternGenerator *gen=udatpg_open(loc,&status);if(!gen)return -2;UChar best[128];int32_t len=udatpg_getBestPattern(gen,pattern16,plen,best,128,&status);memcpy(pattern16,best,(size_t)len*sizeof(UChar));plen=len;udatpg_close(gen);}
 UDateFormat *fmt=udat_open(date_style<0&&time_style<0?UDAT_PATTERN:(UDateFormatStyle)time_style,date_style<0&&time_style<0?UDAT_PATTERN:(UDateFormatStyle)date_style,loc,zone16,zlen,pattern16,plen,&status);if(U_FAILURE(status)||!fmt)return status==U_MEMORY_ALLOCATION_ERROR?-2:-1;
 UCalendar *cal=ucal_clone(udat_getCalendar(fmt),&status);if(cal){if(strcmp(calendar,"gregory")==0||strcmp(calendar,"iso8601")==0)ucal_setGregorianChange(cal,-8.64e15,&status);udat_setCalendar(fmt,cal);ucal_close(cal);}
 int32_t len=udat_format(fmt,millis,result,1024,NULL,&status);udat_close(fmt);int32_t bytes=0;u_strToUTF8(out,capacity,&bytes,result,len,&status);return U_SUCCESS(status)?bytes:(status==U_MEMORY_ALLOCATION_ERROR?-2:-1);
}
int z_calendar_diff(const char *id,int64_t origin,int64_t target,int largest,int64_t *years,int64_t *months,int64_t *days) {
 UErrorCode status=U_ZERO_ERROR;UCalendar *cal=open_calendar(id,&status);if(!cal)return 2;ucal_setMillis(cal,(double)origin*86400000.,&status);
 *years=0;*months=0;if(largest==0)*years=ucal_getFieldDifference(cal,(double)target*86400000.,UCAL_YEAR,&status);
 if(largest<=1)*months=ucal_getFieldDifference(cal,(double)target*86400000.,UCAL_MONTH,&status);
 *days=target-(int64_t)floor(ucal_getMillis(cal,&status)/86400000.);ucal_close(cal);return U_SUCCESS(status)?0:1;
}

const char *z_icu_version(void){return U_ICU_VERSION;}
int z_system_zone(char *out,int capacity) {
 UErrorCode status=U_ZERO_ERROR;UChar value[256];int32_t length=ucal_getDefaultTimeZone(value,256,&status),bytes=0;
 u_strToUTF8(out,capacity,&bytes,value,length,&status);return U_SUCCESS(status)?bytes:(status==U_MEMORY_ALLOCATION_ERROR?-2:-1);
}
