# 4d-plugin-hash
Compute checksum of a file

###Platform

| carbon | cocoa | win32 | win64 |
|:------:|:-----:|:---------:|:---------:|
|🆗|🆗|🆗|🆗|

###Version

<img src="https://cloud.githubusercontent.com/assets/1725068/18940649/21945000-8645-11e6-86ed-4a0f800e5a73.png" width="32" height="32" /> <img src="https://cloud.githubusercontent.com/assets/1725068/18940648/2192ddba-8645-11e6-864d-6d5692d55717.png" width="32" height="32" />

###Supported hash algorithms

```
Checksum MD5 0
Checksum SHA1 1
Checksum SHA256 2
Checksum SHA384 3
Checksum SHA512 5
```

###Supported output formats

```
Checksum Format Hex 0
Checksum Format Base64 1
```

```
hash:=Generate checksum (path;type;format;method)
```

###Syntax

param|type|description
------------|------|----
path|TEXT|full path in system format 
type|INT32|hash algorithm
format|TEXT|output format
method|INT32|(optional)callback method
hash|TEXT|hash (empty if aborted)

###Syntax for callback method

param|type|description
------------|------|----
$1|REAL|current read position
$2|REAL|total file size
$0|BOOL|```True``` to abort

###Discussion

* OpenSSL is used internally. 

* The callback method is called by its method ID. If a method name is passed, but a corresponding method is not found, EXECUTE METHOD is used internally. This can be useful, for example, if the callback method is a shared component method.

* The callback method is called in the process which called the plugin.
