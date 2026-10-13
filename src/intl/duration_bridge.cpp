#include <unicode/numberformatter.h>
#include <unicode/listformatter.h>
#include <unicode/measunit.h>
#include <unicode/ustring.h>
#include <unicode/uloc.h>
#include <cmath>
#include <memory>
using namespace icu;
using namespace icu::number;
static UnicodeString format_number(double value,int minDigits,const Locale& locale,UErrorCode& status) {
 return NumberFormatter::with().precision(Precision::maxFraction(9)).integerWidth(IntegerWidth::zeroFillTo(minDigits)).locale(locale).formatDouble(value,status).toString(status);
}
extern "C" int z_locale_duration(const char *tag,const double *values,int style,int digits,char *out,int capacity) {
 UErrorCode status=U_ZERO_ERROR;int parsed=0;char localeId[128];uloc_forLanguageTag(tag,localeId,sizeof localeId,&parsed,&status);if(U_FAILURE(status)||parsed!=(int)strlen(tag))return -1;
 Locale locale(localeId);UnicodeString parts[11];int count=0;bool negative=false,signEmitted=false;
 for(int i=0;i<10;i++)if(values[i]<0)negative=true;
 const char *names[]={"year","month","week","day","hour","minute","second","millisecond","microsecond","nanosecond"};
 const UNumberUnitWidth unitWidth=style==0?UNUM_UNIT_WIDTH_FULL_NAME:(style==2?UNUM_UNIT_WIDTH_NARROW:UNUM_UNIT_WIDTH_SHORT);
 const int stop=style==3?4:10;
 for(int i=0;i<stop;i++) {
  if(values[i]==0)continue;
  double value=std::abs(values[i]);if(negative&&!signEmitted)value=-value;
  auto unit=MeasureUnit::forIdentifier(names[i],status);
  parts[count++]=NumberFormatter::with().unit(unit).unitWidth(unitWidth).precision(Precision::maxFraction(9)).locale(locale).formatDouble(value,status).toString(status);signEmitted=true;
 }
 if(style==3) {
  double hour=std::abs(values[4]),minute=std::abs(values[5]);double second=std::abs(values[6])+std::abs(values[7])/1000.+std::abs(values[8])/1e6+std::abs(values[9])/1e9;
  if(digits>=0){const double scale=std::pow(10.,digits);second=std::trunc(second*scale)/scale;}
  UnicodeString time=format_number(negative&&!signEmitted?-hour:hour,1,locale,status);time.append(u':').append(format_number(minute,2,locale,status)).append(u':');
  auto formatter=NumberFormatter::with().integerWidth(IntegerWidth::zeroFillTo(2)).precision(digits>=0?Precision::fixedFraction(digits):Precision::maxFraction(9)).locale(locale);
  time.append(formatter.formatDouble(second,status).toString(status));parts[count++]=time;
 }
 if(count==0) {auto unit=MeasureUnit::getSecond();parts[count++]=NumberFormatter::with().unit(unit).unitWidth(unitWidth).locale(locale).formatDouble(0,status).toString(status);}
 const UListFormatterWidth width=style==0?ULISTFMT_WIDTH_WIDE:(style==2?ULISTFMT_WIDTH_NARROW:ULISTFMT_WIDTH_SHORT);
 std::unique_ptr<ListFormatter> list(ListFormatter::createInstance(locale,ULISTFMT_TYPE_UNITS,width,status));if(!list)return -2;
 UnicodeString result;list->format(parts,count,result,status);int bytes=0;u_strToUTF8(out,capacity,&bytes,result.getBuffer(),result.length(),&status);
 return U_SUCCESS(status)?bytes:(status==U_MEMORY_ALLOCATION_ERROR?-2:-1);
}
