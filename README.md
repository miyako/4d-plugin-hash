# 4d-plugin-hash

Hash computes the checksum of a file on disk and returns it as `Text`. It uses OpenSSL's digest functions (OpenSSL 3.2.1, linked into the plugin, so nothing else needs to be installed) to compute MD5, SHA-1, SHA-256, SHA-384 or SHA-512, encoded as lowercase hexadecimal or Base64. The file is read in 1 MB chunks, so its size doesn't affect memory use. An optional callback method receives progress updates and can cancel the operation.

| Command | Returns | Purpose |
|---|---|---|
| [Generate checksum](#generate-checksum) | `Text` | Compute the MD5/SHA checksum of a file, with optional progress and cancel |

**Platforms:** macOS (Apple silicon and Intel), Windows (64-bit)

---

## Requirements & platform notes

- **The plugin has one command, and it takes four parameters:** path, algorithm, format and callback method. Pass `""` as the fourth parameter when you don't want progress updates. The manifest declares all four (`Generate checksum(&T;&L;&L;&T):T`). The original README called the callback optional, but always passing it is the safe form.
- **Failure is silent, not a 4D error.** If the file can't be read, or you cancel, the command returns `""` and raises no 4D error. Check the result before using it (see [Error handling & troubleshooting](#error-handling--troubleshooting)).
- **On macOS, the path must be a system (HFS, colon-separated) path**, such as the ones `System folder`, `Get 4D folder` or `Select document` return. A POSIX path like `/Users/me/file.zip` is not converted and won't be found. Convert it first with `Convert path POSIX to system`, or use a `File` object's `.platformPath`.
- **Only regular files are hashed.** A folder, a named pipe or a device returns `""`. Symbolic links are followed. A macOS Finder alias is not resolved: you get the checksum of the alias file itself.
- **The command runs in the calling process and doesn't return until it's done.** Between 1 MB chunks it lets other 4D processes run, so the application stays responsive, but the calling process itself is blocked. Use a callback method if you want the user to be able to cancel.
- **Preemptive processes:** the manifest doesn't declare the command thread-safe, so expect 4D to treat it as unusable in preemptive processes. If you need that, check your version's documentation on plugin thread safety.

---

## Generate checksum

### Syntax

```
Generate checksum ( path ; type ; format ; method ) → hash
```

| Parameter | Type | Description |
|---|---|---|
| `path` | Text | Full path of the file, in system format (on macOS, colon-separated HFS style) |
| `type` | Longint | Algorithm: one of the `Checksum Type` constants below. Any other value gives MD5 |
| `format` | Longint | Output encoding: `Checksum Format Base64` (`1`). Any other value, including `Checksum Format Hex` (`0`), gives hexadecimal |
| `method` | Text | Name of the progress callback method, or `""` for none |
| Result | Text | The checksum, or `""` if the file couldn't be read or you cancelled |

**Checksum Type constants**

| Constant | Value | Result length (hex / Base64) |
|---|---|---|
| `Checksum MD5` | `0` | 32 / 24 characters |
| `Checksum SHA1` | `1` | 40 / 28 characters |
| `Checksum SHA256` | `2` | 64 / 44 characters |
| `Checksum SHA384` | `3` | 96 / 64 characters |
| `Checksum SHA512` | `5` | 128 / 88 characters |

There is no constant with value `4`. Passing `4`, or any other value not in this table, silently gives MD5.

**Checksum Format constants**

| Constant | Value | Encoding |
|---|---|---|
| `Checksum Format Hex` | `0` | Lowercase hexadecimal, two digits per byte (`"d41d8cd98f00b204e9800998ecf8427e"`) |
| `Checksum Format Base64` | `1` | Standard Base64 (`A–Z a–z 0–9 + /`), padded with `=` |

### Description

`Generate checksum` opens the file at `path` read-only, runs it through the chosen digest algorithm, and returns the encoded result. The file is read sequentially in 1 MB chunks, so a multi-gigabyte file costs no more memory than a small one.

**The callback method.** When `method` names a project method, it's called with progress information and its return value decides whether to continue:

| Parameter | Type | Description |
|---|---|---|
| `$1` | Real | Number of bytes read so far |
| `$2` | Real | Total size of the file in bytes |
| `$0` | Boolean | Return `True` to cancel, `False` to continue |

- The callback runs **in the calling process**, so it can use that process's process variables (the plugin's own sample keeps the `Progress` ID in a process variable, `PID`).
- It's called **at most every 100 ms** while the file is being read, plus **once at the end** with `$1 = $2`. A file that takes less than 100 ms to read gets exactly one call, at the end. An empty file gets no calls.
- If `$0` is `True`, reading stops and the command returns `""`. Returning `True` from the final call also cancels, and the command returns `""` even though the whole file was read.
- If `$0` isn't a Boolean (for example, the method doesn't set it), the command continues.
- **Methods not found by name:** the plugin first looks up `method` as a project method of the host database. If no project method has that name, it calls the method with `EXECUTE METHOD` instead, passing the same two parameters and reading `$0` the same way. That lets you use a method shared by a component.
- `$1` and `$2` are Reals, so files larger than 2 GB report correctly.

### Example

From the plugin's own test method (`Method1.4dm`). It shows a cancellable progress bar using the 4D Progress component:

```4d
PID:=Progress New
Progress SET PROGRESS(PID; -1)
Progress SET BUTTON ENABLED(PID; True:C214)

$path:=System folder:C487(Desktop:K41:16)+"openssl-OpenSSL_1_1_0-stable.zip"

$callbackMethod:="PROGRESS"

$hash:=Generate checksum($path; Checksum MD5; Checksum Format Base64; $callbackMethod)

Progress QUIT(PID)

If ($hash#"")
	
	ALERT:C41($hash)
	
Else 
	
	ALERT:C41("Aborted!")
	
End if 
```

And the matching callback, from the plugin's own `PROGRESS.4dm`:

```4d
C_REAL:C285($1; $POS)
C_REAL:C285($2; $LEN)
C_BOOLEAN:C305($0)

$POS:=$1
$LEN:=$2

$progress:=$POS/$LEN
$message:=String:C10($POS)+"/"+String:C10($LEN)+" bytes"

Progress SET PROGRESS(PID; $progress; $message)

DELAY PROCESS:C323(Current process:C322; 5)

$0:=Progress Stopped(PID)
```

The `DELAY PROCESS` in the sample only slows the demo down so you can watch the bar move. Remove it in real code: it adds 5 ticks (about 83 ms) to every callback.

Hash a file without a callback, as SHA-256 in hexadecimal:

```4d
$path:=System folder:C487(Desktop:K41:16)+"installer.dmg"
$hash:=Generate checksum($path; Checksum SHA256; Checksum Format Hex; "")

If ($hash="")
	ALERT:C41("Could not read "+$path)
End if 
```

Check a download against a published SHA-256:

```4d
$expected:="9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
$hash:=Generate checksum($path; Checksum SHA256; Checksum Format Hex; "")

Case of 
	: ($hash="")
		ALERT:C41("File not readable.")
	: ($hash=$expected)
		ALERT:C41("Checksum OK.")
	Else 
		ALERT:C41("Checksum mismatch: the file is damaged or was altered.")
End case 
```

Compare hexadecimal results like this, not Base64: 4D's `=` ignores case, which is harmless for hex digits but would treat two different Base64 strings as equal if they differ only in case.

Hash every file in a folder. This uses `Folder`/`File` objects, so it needs a 4D version that has them (v18 or later). `.platformPath` gives the system-format path the command expects:

```4d
$results:=New object
For each ($file; Folder(fk desktop folder).files())
	$results[$file.fullName]:=Generate checksum($file.platformPath; Checksum SHA1; Checksum Format Hex; "")
End for each 
```

---

## Error handling & troubleshooting

- **The result is `""`.** The command never raises a 4D error. It returns `""` when the path doesn't exist, isn't a regular file (a folder, pipe or device), can't be opened (no read permission, or on Windows another application holding it open without read sharing), when a read error happens partway through, or when the callback returns `True`. A read error never produces a partial checksum: you get `""`.
- **Every path fails on macOS.** You're probably passing a POSIX path (`/Users/...`). The command expects a system (HFS) path; convert it with `Convert path POSIX to system` or use `File(...).platformPath`.
- **Unexpected checksum length.** An algorithm value that isn't one of the constants, including `4`, silently gives MD5 (32 hex characters). Use the constants rather than literal numbers.
- **The result is Base64 when you expected hex, or the other way round.** Only `1` gives Base64; every other format value gives hex.
- **The callback is never called, or called only once.** Calls are limited to one every 100 ms plus one at the end, so a small file gets a single call. Check that the method name is spelled exactly as in your project, or as shared by the component. An empty file gets no call.
- **The callback can't stop the hash.** Make sure it sets `$0` to `True`. Any other value, or no value at all, means "continue".
- **Hashing is slow.** If you use a callback, keep it light: it runs up to 10 times a second in the calling process. Don't put `DELAY PROCESS` or heavy UI work in it.

---

## Quick reference

```4d
// SHA-256, hex, no progress
$hash:=Generate checksum($path; Checksum SHA256; Checksum Format Hex; "")

// MD5, Base64, cancellable progress ($1 bytes read, $2 total, $0 True to cancel)
$hash:=Generate checksum($path; Checksum MD5; Checksum Format Base64; "PROGRESS")

// POSIX path → system path (macOS)
$hash:=Generate checksum(Convert path POSIX to system($posix); Checksum SHA512; Checksum Format Hex; "")

If ($hash="")
	// unreadable, not a regular file, read error, or cancelled
End if 
```
