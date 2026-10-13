import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
const runner = process.argv[2];
if (!globalThis.Temporal) throw new Error('Node with native Temporal is required');
console.log(JSON.stringify({node:process.version,icu:process.versions.icu,tz:process.versions.tz,unicode:process.versions.unicode}));
const cases = [];
const add = (kind,op,a,b,options={}) => cases.push({kind,op,a,...(b===undefined?{}:{b}),options});
for (const [kind,values] of Object.entries({PlainDate:['20240229','2024-02-29','2024-02-29[!foo=bar]','2024-02-30','-000000-01-01'],PlainTime:['12','T12','1234','123456','202402','T202402','00:00[U-CA=iso8601]','T00:00[u-CA=iso8601]','00:00[FOO=bar]','00:00[!foo=bar]','00:00[foo=_bar]','12:00:00.1234567890','12:00:60','T0102','0102','123456.123','12:00Z'],PlainDateTime:['-271821-04-19T00:00:00','-271821-04-19T00:00:00.000000001','20240229T123456','2024-02-29T12:00'],PlainYearMonth:['202402','2024-02','2024-02-30','2024-02T12:00'],PlainMonthDay:['02-29T12:00','--02-29T12:00','--0229','02-29','20230229'],Instant:['20240229T123456Z','2024-02-29T12:00Z[!foo=bar]'],Duration:['PT9007199254740993N','PT0.1S','P1Y','PT10000000000000000000S'],ZonedDateTime:['2024-02-29T12:00+05:30[+05:30]','2024-02-29T12:00Z[America/New_York]','1880-01-01T12:00+00:09[Europe/Paris]','2024-11-03T01:30-05:00[America/New_York]']})) for(const a of values) add(kind,'from',a);
for(const mode of ['ceil','floor','trunc','expand','halfCeil','halfFloor','halfTrunc','halfExpand','halfEven']) {
 for(const [a,b] of [['2024-05-29','2024-01-10'],['2024-01-31','2024-03-01'],['2024-03-01','2024-01-31']]) for(const smallestUnit of ['week','month','year']) for(const op of ['until','since']) add('PlainDate',op,a,b,{largestUnit:'year',smallestUnit,roundingMode:mode});
 for(const smallestUnit of ['week','month','year']) for(const op of ['until','since']) add('PlainDateTime',op,'2024-01-01T12:00','2024-02-15T11:59:59.999999999',{largestUnit:'year',smallestUnit,roundingMode:mode});
 for(const smallestUnit of ['day','hour']) add('ZonedDateTime','round','2024-03-10T12:00[America/New_York]',undefined,{smallestUnit,roundingMode:mode});
}
for(const digits of [0,1,2,3,6,9,10]) for(const kind of ['PlainTime','PlainDateTime','Instant','ZonedDateTime','Duration']) add(kind,'toString',({PlainTime:'12:34:56.123456789',PlainDateTime:'2024-12-31T23:59:59.999999999',Instant:'1969-12-31T23:59:59.999999999Z',ZonedDateTime:'2024-03-10T01:59:59.999999999[America/New_York]',Duration:'P1DT2H3M4.123456789S'})[kind],undefined,{fractionalSecondDigits:digits});
for(const zone of ['America/New_York','America/Santiago','Australia/Lord_Howe','Pacific/Apia','UTC','+05:30']) {
 const a=`2024-03-09T12:00[${zone}]`, b=`2024-03-11T12:00[${zone}]`;
 for(const duration of ['P1D','PT24H','P1M','-P1D']) add('ZonedDateTime','add',a,duration);
 for(const largestUnit of ['hour','day','month']) add('ZonedDateTime','until',a,b,{largestUnit});
 for(const unit of ['hour','day','week','month']) add('Duration','total','P2D',undefined,{relativeTo:a,unit});
}
for(const unit of ['week','month','year']) add('Duration','total','P1M14DT12H',undefined,{relativeTo:'2024-01-01',unit});

for(const op of ['until','since'])add('ZonedDateTime',op,'2024-11-03T01:30-05:00[America/New_York]','2024-11-03T02:30-05:00[America/New_York]',{largestUnit:'day'});
add('Duration','round','PT2H',undefined,{relativeTo:'2024-11-03T01:30-05:00[America/New_York]',largestUnit:'day'});
add('Instant','until','1970-01-01T00:00Z','1994-07-12T09:59:17.755723856Z',{largestUnit:'nanosecond'});
add('Duration','compare','P1M','P30D',{relativeTo:'2024-02-01'});
if(process.argv[3]==='intl') {
 for(const locales of ['en-US','es-CL','de-DE','fr-FR']) {
  add('PlainDateTime','toLocaleString','2024-12-31T23:59:59.999999999',undefined,{locales});
  add('Instant','toLocaleString','1969-12-31T23:59:59.999999999Z',undefined,{locales,localeOptions:{timeZone:'UTC'}});
  add('ZonedDateTime','toLocaleString','2024-02-29T12:34:56+05:30[+05:30]',undefined,{locales});
  for(const [kind,a] of Object.entries({PlainDate:'2024-02-29',PlainTime:'12:34:56',PlainDateTime:'2024-02-29T12:34:56',PlainYearMonth:'2024-02',PlainMonthDay:'02-29',ZonedDateTime:'2024-02-29T12:34:56[America/New_York]',Duration:'P1DT2H30M'})) {
   add(kind,'toLocaleString',a,undefined,{locales,localeOptions:kind==='PlainYearMonth'||kind==='PlainMonthDay'?{calendar:'iso8601'}:{}});
   if(kind==='Duration')for(const style of ['long','short','narrow','digital'])add(kind,'toLocaleString',a,undefined,{locales,durationLocaleOptions:{style}});
  }
 }

 for(const calendar of Intl.supportedValuesOf('calendar').filter(c=>!['islamic','islamic-rgsa'].includes(c))) {
  for(const date of ['2024-02-29','2023-03-22','2000-01-01','1900-03-01']) {
   for(const kind of ['PlainDate','PlainDateTime','PlainYearMonth','PlainMonthDay','ZonedDateTime']) {
    const input=kind==='ZonedDateTime'?`${date}T12:34:56[America/New_York][u-ca=${calendar}]`:kind==='PlainDateTime'?`${date}T12:34:56[u-ca=${calendar}]`:`${date}[u-ca=${calendar}]`;
    add(kind,'from',input); if(kind!=='ZonedDateTime')add(kind,'properties',input);
   }
  }
  for(const d of ['P1Y','P1M','-P1M','P15D']) add('PlainDate','add',`2024-02-29[u-ca=${calendar}]`,d);
 }
}
let seed=0x742b;
const rand=(n)=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;};
for(let i=0;i<100;i++) {
 const a=`${2020+rand(6)}-${String(1+rand(12)).padStart(2,'0')}-${String(1+rand(28)).padStart(2,'0')}`;
 const b=`${2020+rand(6)}-${String(1+rand(12)).padStart(2,'0')}-${String(1+rand(28)).padStart(2,'0')}`;
 add('PlainDateTime','until',`${a}T${String(rand(24)).padStart(2,'0')}:30`,`${b}T${String(rand(24)).padStart(2,'0')}:45`,{largestUnit:['year','month','week','day','hour'][rand(5)],smallestUnit:['week','day','hour'][rand(3)],roundingMode:['halfExpand','floor','trunc'][rand(3)]});
}
const components = d => Object.fromEntries(['years','months','weeks','days','hours','minutes','seconds','milliseconds','microseconds','nanoseconds'].map(k=>[k,d[k]]));
function reference(c) {
 try {
  const C=Temporal[c.kind], a=C.from(c.a,c.options); let result;
  if(c.op==='properties') {const names=['year','month','monthCode','day','era','eraYear','daysInYear','daysInMonth','monthsInYear','inLeapYear'];return {properties:Object.fromEntries(names.filter(k=>a[k]!==undefined).map(k=>[k,a[k]]))};}
  if(c.op==='from') result=a;
  else if(c.op==='compare') return {number:C.compare(a,C.from(c.b),c.options)};
  else if(c.op==='total') return {number:a.total(c.options)};
  else if(c.op==='toString') return {result:a.toString(c.options),...(c.kind==='Duration'?{components:components(a)}:{})};
  else if(c.op==='toLocaleString') return {result:a.toLocaleString(c.options.locales,c.kind==='Duration'?c.options.durationLocaleOptions:c.options.localeOptions)};
  else if(c.op==='toJSON') return {result:a.toJSON()};
  else if(c.op==='round') result=a.round(c.options);
  else result=a[c.op](c.op==='add'||c.op==='subtract'?Temporal.Duration.from(c.b):C.from(c.b),c.options);
  return {result:result.toString(),...(result instanceof Temporal.Duration?{components:components(result)}:{})};
 } catch(e) {return {errorName:e.name};}
}
let failures=0;
for(const c of cases) {
 const expected=reference(c);
 if(c.op==='from'&&c.kind==='Duration'&&!expected.errorName) expected.components=components(Temporal.Duration.from(c.a));
 const run=spawnSync(runner,[JSON.stringify(c)],{encoding:'utf8'});
 if(run.status!==0) {console.error('runner failure',c,run.stderr); failures++; continue;}
 let actual; try{actual=JSON.parse(run.stdout)}catch(e){console.error('bad runner response',run.stdout);failures++;continue;}
 try { if(expected.number!==undefined&&actual.number!==undefined) { assert.ok(Object.is(expected.number,actual.number)); } else assert.deepEqual(actual,expected); }
 catch { if(failures<20) console.error(JSON.stringify({case:c,expected,actual}));failures++; }
}
console.log(`${cases.length-failures}/${cases.length} parity cases passed`);
if(failures) process.exitCode=1;
