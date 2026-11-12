/*
 * Synthetic 4D engine boundary for Hash ownership regressions.
 *
 * Links the real plugin source (4DPlugin.cpp, with the vendored OpenSSL),
 * the plugin classes (4D Plugin API/Classes) and the bundled, unmodified
 * 4D Plugin API (4DPluginAPI.c). Only gCall4D is replaced: it models
 * engine-side allocations (Unistrings, handles, pictures) with malloc/free
 * so ASan reports double frees and use-after-free, and keeps a live set of
 * every engine string and picture so leaks are detected exactly.
 *
 * Engine semantics modelled (SDK contract):
 *  - PA_CreateVariable(eVK_Unistring / eVK_Picture) allocates an empty
 *    engine string / picture (4DPluginAPI.c); PA_SetStringVariable and
 *    PA_SetPictureVariable overwrite the variable shallowly.
 *  - PA_ClearVariable releases what the variable owns.
 *  - Pictures are reference counted: PA_DuplicatePicture(p, 1) retains,
 *    PA_DisposePicture releases one reference.
 *  - Commands that write a picture into an output parameter (READ PICTURE
 *    FILE, CREATE THUMBNAIL) release the picture previously held by that
 *    variable (the most forgiving engine model).
 *  - PA_ConvertCharsetToCharset returns the BYTE size written (SDK comment).
 *  - EXECUTE METHOD (1007) and PA_ExecuteMethodByID read their parameters;
 *    the caller keeps ownership and clears them afterwards. A ByID result
 *    is caller-owned.
 *
 * The only file touched on disk is a 3-byte temp file created by the test.
 */

#include "4DPluginAPI.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"
#include "4DPlugin.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <unistd.h>

extern "C" Call4DProcPtr gCall4D;

namespace {

typedef std::basic_string<PA_Unichar> u16;

struct Handle { char *data; PA_long32 len; };
struct Pic { int refs; };

std::set<void *> g_strings;
std::set<Handle *> g_handles;
std::set<Pic *> g_pics;

const PA_long32 kCallbackId = 4242;
const u16 kCallbackName = (const PA_Unichar *)u"HASH_PROGRESS";
const u16 kUnresolved = (const PA_Unichar *)u"HASH_UNRESOLVED";

bool g_return_text = false;
bool g_abort = false;
void *g_returned = 0;

struct Call { int calls = 0; u16 method; double pos = 0, total = 0; };
Call g_byid, g_cmd;
u16 g_read_path, g_convert_type;
int g_transform_op = 0, g_thumb_w = 0, g_thumb_h = 0;

[[noreturn]] void die(const char *msg) {
    fprintf(stderr, "ENGINE VIOLATION: %s\n", msg);
    fflush(stderr);
    abort();
}

PA_Unistring new_string(const PA_Unichar *src, size_t len) {
    PA_Unichar *buf = (PA_Unichar *)malloc((len + 1) * sizeof(PA_Unichar));
    if(len) memcpy(buf, src, len * sizeof(PA_Unichar));
    buf[len] = 0;
    g_strings.insert(buf);
    PA_Unistring s;
    s.fLength = (PA_long32)len;
    s.fString = buf;
    s.fReserved1 = 0;
    s.fReserved2 = 0;
    return s;
}

void free_string(PA_Unistring *s) {
    if(!s->fString) return;
    if(!g_strings.erase(s->fString)) die("disposed a string the engine does not own");
    free(s->fString);
    s->fString = 0;
    s->fLength = 0;
}

Handle *new_handle(PA_long32 len) {
    Handle *h = (Handle *)malloc(sizeof(Handle));
    h->data = (char *)calloc(1, len ? len : 1);
    h->len = len;
    g_handles.insert(h);
    return h;
}

Handle *checked(PA_Handle ph) {
    Handle *h = (Handle *)ph;
    if(!g_handles.count(h)) die("used an unknown handle");
    return h;
}

void free_handle(Handle *h) {
    if(!h) return;
    checked((PA_Handle)h);
    g_handles.erase(h);
    free(h->data);
    free(h);
}

Pic *new_pic() {
    Pic *p = (Pic *)malloc(sizeof(Pic));
    p->refs = 1;
    g_pics.insert(p);
    return p;
}

Pic *live_pic(PA_Picture pp) {
    Pic *p = (Pic *)pp;
    if(!g_pics.count(p)) die("used a picture the engine does not own");
    return p;
}

void release_pic(PA_Picture pp) {
    if(!pp) return;
    Pic *p = live_pic(pp);
    if(--p->refs == 0) { g_pics.erase(p); free(p); }
}

void clear_var(PA_Variable *v) {
    switch(v->fType) {
        case eVK_Unistring: free_string(&v->uValue.fString); break;
        case eVK_Picture: release_pic(v->uValue.fPicture); v->uValue.fPicture = 0; break;
        case eVK_ArrayUnicode: {
            Handle *h = (Handle *)v->uValue.fArray.fData;
            if(h) {
                PA_Unistring *items = (PA_Unistring *)checked((PA_Handle)h)->data;
                for(PA_long32 i = 0; i <= v->uValue.fArray.fNbElements; ++i) free_string(&items[i]);
                free_handle(h);
            }
            break;
        }
        default: break;
    }
    v->fType = eVK_Undefined;
}

u16 live_text(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Unistring) die(what);
    if(!g_strings.count(v.uValue.fString.fString)) die("engine received a string it does not own");
    return u16(v.uValue.fString.fString, v.uValue.fString.fLength);
}

void live_picture_var(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Picture || !v.uValue.fPicture) die(what);
    live_pic(v.uValue.fPicture);
}

PA_long32 longint(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Longint) die(what);
    return v.uValue.fLongint;
}

double real(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Real) die(what);
    return v.uValue.fReal;
}

/* output picture parameter: the engine releases the old value and stores a new picture */
void write_picture(PA_Variable *v) {
    if(v->fType == eVK_Picture) release_pic(v->uValue.fPicture);
    else if(v->fType != eVK_Undefined) die("picture output parameter has a non-picture value");
    v->fType = eVK_Picture;
    v->uValue.fPicture = new_pic();
}

void command(EngineBlock *eb) {
    PA_Variable **v = (PA_Variable **)eb->fPtr1;
    PA_long32 n = (PA_long32)eb->fParam2;
    switch(eb->fParam1) {
        case 1007: /* EXECUTE METHOD(name; $0; pos; total) */
            if(n != 4) die("EXECUTE METHOD parameter count");
            g_cmd.calls++;
            g_cmd.method = live_text(*v[0], "method name parameter is not text");
            if(v[1]->fType != eVK_Boolean) die("result parameter is not boolean");
            g_cmd.pos = real(*v[2], "pos parameter is not real");
            g_cmd.total = real(*v[3], "total parameter is not real");
            v[1]->uValue.fBoolean = g_abort ? 1 : 0;
            break;
        case 678: /* READ PICTURE FILE(path; picture) */
            if(n != 2) die("READ PICTURE FILE parameter count");
            g_read_path = live_text(*v[0], "path parameter is not text");
            write_picture(v[1]);
            break;
        case 1002: /* CONVERT PICTURE(picture; type) */
            if(n != 2) die("CONVERT PICTURE parameter count");
            live_picture_var(*v[0], "CONVERT PICTURE picture");
            g_convert_type = live_text(*v[1], "type parameter is not text");
            break;
        case 988: /* TRANSFORM PICTURE(picture; operator) */
            if(n != 2) die("TRANSFORM PICTURE parameter count");
            live_picture_var(*v[0], "TRANSFORM PICTURE picture");
            g_transform_op = longint(*v[1], "operator is not longint");
            break;
        case 457: /* PICTURE PROPERTIES(picture; width; height) */
            if(n != 3) die("PICTURE PROPERTIES parameter count");
            live_picture_var(*v[0], "PICTURE PROPERTIES picture");
            v[1]->fType = eVK_Longint; v[1]->uValue.fLongint = 640;
            v[2]->fType = eVK_Longint; v[2]->uValue.fLongint = 480;
            break;
        case 679: /* CREATE THUMBNAIL(picture; thumbnail; width; height) */
            if(n != 4) die("CREATE THUMBNAIL parameter count");
            live_picture_var(*v[0], "CREATE THUMBNAIL source");
            g_thumb_w = longint(*v[2], "width is not longint");
            g_thumb_h = longint(*v[3], "height is not longint");
            write_picture(v[1]);
            break;
        default: die("unexpected command");
    }
    eb->fError = 0;
}

void engine(PA_long32 selector, void *p) {
    EngineBlock *eb = (EngineBlock *)p;
    switch(selector) {
        case EX_HANDLE_MANAGER:
            switch(eb->fParam1) {
                case 1: eb->fHandle = (PA_Handle)new_handle((PA_long32)eb->fParam2); eb->fError = 0; return;
                case 2: free_handle((Handle *)eb->fHandle); eb->fError = 0; return;
                case 3: {
                    Handle *h = checked(eb->fHandle);
                    PA_long32 n = (PA_long32)eb->fParam2;
                    h->data = (char *)realloc(h->data, n ? n : 1);
                    if(n > h->len) memset(h->data + h->len, 0, n - h->len);
                    h->len = n; eb->fError = 0; return;
                }
                case 4: eb->fParam2 = checked(eb->fHandle)->len; eb->fError = 0; return;
                case 5: eb->fParam3 = (sLONG_PTR)checked(eb->fHandle)->data; eb->fError = 0; return;
                case 6: checked(eb->fHandle); eb->fError = 0; return;
                default: die("unmodelled handle manager call");
            }
        case EX_CREATE_UNISTRING: {
            const PA_Unichar *s = (const PA_Unichar *)eb->fHandle;
            size_t n = 0; while(s[n]) ++n;
            eb->fUniString1 = new_string(s, n);
            return;
        }
        case EX_SET_UNISTRING: {
            const PA_Unichar *s = (const PA_Unichar *)eb->fHandle;
            size_t n = 0; while(s[n]) ++n;
            free_string(&eb->fUniString1);
            eb->fUniString1 = new_string(s, n);
            return;
        }
        case EX_DISPOSE_UNISTRING: free_string(&eb->fUniString1); return;
        case EX_CLEAR_VARIABLE: clear_var((PA_Variable *)eb->fPtr1); return;
        case EX_YIELD_ABSOLUTE: return;
        case EX_CREATE_PICTURE: eb->fPicture = new_pic(); eb->fError = 0; return;
        case EX_DISPOSE_PICTURE: release_pic(eb->fPicture); return;
        case EX_DUPLICATE_PICTURE:
            if(eb->fParam1 == 0) live_pic(eb->fPicture)->refs++;
            else { live_pic(eb->fPicture); eb->fPicture = new_pic(); }
            return;
        case EX_GET_PICTURE_DATA:
            live_pic(eb->fPicture);
            memset(&eb->fUniString1, 0, sizeof eb->fUniString1);
            eb->fError = -1; /* no stored formats */
            return;
        case EX_CONVERT_CHARSET_TO_CHARSET: {
            const char *from = (const char *)eb->fPtr1;
            PA_long32 fromSize = (PA_long32)eb->fParam1, toSize = (PA_long32)eb->fParam3, out = 0;
            if(eb->fParam2 == eVTC_UTF_8 && eb->fParam4 == eVTC_UTF_16) {
                PA_Unichar *to = (PA_Unichar *)eb->fPtr2;
                for(PA_long32 i = 0; i < fromSize && (out + 1) * (PA_long32)sizeof(PA_Unichar) <= toSize; ++i)
                    to[out++] = (unsigned char)from[i];
                eb->fParam3 = out * (PA_long32)sizeof(PA_Unichar); /* byte size */
            } else if(eb->fParam2 == eVTC_UTF_16 && eb->fParam4 == eVTC_UTF_8) {
                const PA_Unichar *f = (const PA_Unichar *)from;
                char *to = (char *)eb->fPtr2;
                for(PA_long32 i = 0; i < fromSize / 2 && out < toSize; ++i) to[out++] = (char)f[i];
                eb->fParam3 = out;
            } else die("unmodelled charset conversion");
            eb->fError = 0;
            return;
        }
        case EX_GET_METHOD_ID:
            eb->fParam1 = (u16(eb->fUName) == kCallbackName) ? kCallbackId : 0;
            eb->fError = 0;
            return;
        case EX_CALL_BY_PROCID: {
            if(eb->fParam1 != kCallbackId || eb->fParam2 != 2) die("unexpected method call");
            PA_Variable *v = (PA_Variable *)checked(eb->fHandle)->data;
            g_byid.calls++;
            g_byid.pos = real(v[1], "pos parameter is not real");
            g_byid.total = real(v[2], "total parameter is not real");
            if(g_return_text) {
                static const PA_Unichar ret[] = { 'o', 'k' };
                v[0].fType = eVK_Unistring;
                v[0].uValue.fString = new_string(ret, 2);
                g_returned = v[0].uValue.fString.fString;
            } else if(g_abort) {
                v[0].fType = eVK_Boolean;
                v[0].uValue.fBoolean = 1;
            }
            eb->fError = 0;
            return;
        }
        case EX_EXECUTE_COMMAND_BY_ID: command(eb); return;
        default: {
            char msg[64];
            snprintf(msg, sizeof msg, "unmodelled selector %d", (int)selector);
            die(msg);
        }
    }
}

void expect(bool ok, const char *what) {
    if(!ok) {
        fprintf(stderr, "FAIL: %s (live engine strings: %zu, pictures: %zu)\n", what, g_strings.size(), g_pics.size());
        exit(1);
    }
}

void expect_nothing_live(const char *what) {
    expect(g_strings.empty(), what);
    expect(g_pics.empty(), what);
}

u16 to_u16(const char *s) { u16 r; for(; *s; ++s) r.push_back((PA_Unichar)(unsigned char)*s); return r; }

/* ---- Generate checksum through PluginMain ---- */

std::string g_file;

/* HFS path of a 3-byte temp file containing "abc" (C_TEXT::convertPath expects HFS) */
u16 temp_file_hfs() {
    char tmpl[] = "/tmp/hash-ownership-XXXXXX";
    int fd = mkstemp(tmpl);
    if(fd < 0 || write(fd, "abc", 3) != 3) die("temp file");
    close(fd);
    g_file = tmpl;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(0, (const UInt8 *)tmpl, strlen(tmpl), false);
    CFStringRef hfs = CFURLCopyFileSystemPath(url, kCFURLHFSPathStyle);
    CFIndex n = CFStringGetLength(hfs);
    u16 r(n, 0);
    CFStringGetCharacters(hfs, CFRangeMake(0, n), (UniChar *)&r[0]);
    CFRelease(hfs);
    CFRelease(url);
    return r;
}

u16 checksum(PA_long32 type, PA_long32 format, const u16 &method) {
    u16 hfs = temp_file_hfs();
    PA_Unistring path = new_string(hfs.c_str(), hfs.size());
    PA_Unistring name = new_string(method.c_str(), method.size());
    PA_Unistring ret = new_string(0, 0);
    PA_Unistring *retp = &ret;
    void *params[4] = { &path, &type, &format, &name };
    PluginBlock pb = { params, &retp, 0 };
    PluginMain(1, &pb); /* Generate checksum */
    unlink(g_file.c_str());
    u16 r(ret.fString, ret.fLength);
    free_string(&path);
    free_string(&name);
    free_string(&ret);
    return r;
}

const u16 kMD5abc = to_u16("900150983cd24fb0d6963f7d28e17f72");

/* ---- tests ---- */

void defect_1007_param_owner_leak() {
    u16 r = checksum(Checksum_MD5, Checksum_Format_Hex, kUnresolved);
    expect(g_cmd.calls == 1, "progress method called once via EXECUTE METHOD");
    expect(r == kMD5abc, "digest returned");
    expect_nothing_live("no engine strings leaked by the EXECUTE METHOD parameters");
}

void control_1007_args_delivered() {
    checksum(Checksum_MD5, Checksum_Format_Hex, kUnresolved);
    expect(g_cmd.calls == 1 && g_byid.calls == 0, "EXECUTE METHOD path taken");
    expect(g_cmd.method == kUnresolved, "method name delivered");
    expect(g_cmd.pos == 3 && g_cmd.total == 3, "progress delivered");
}

void control_1007_abort() {
    g_abort = true;
    u16 r = checksum(Checksum_MD5, Checksum_Format_Hex, kUnresolved);
    expect(g_cmd.calls == 1, "EXECUTE METHOD called");
    expect(r.empty(), "abort honoured");
}

void control_byid_args_delivered() {
    u16 r = checksum(Checksum_SHA256, Checksum_Format_Hex, kCallbackName);
    expect(g_byid.calls == 1 && g_cmd.calls == 0, "ByID path taken");
    expect(g_byid.pos == 3 && g_byid.total == 3, "progress delivered");
    expect(r == to_u16("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "sha256 returned");
    expect_nothing_live("nothing leaked");
}

void control_byid_result_cleared() {
    g_return_text = true;
    checksum(Checksum_MD5, Checksum_Format_Hex, kCallbackName);
    expect(g_byid.calls == 1 && g_returned != 0, "callback returned text");
    expect(!g_strings.count(g_returned), "callback result released");
    expect_nothing_live("nothing leaked");
}

void control_byid_abort() {
    g_abort = true;
    u16 r = checksum(Checksum_MD5, Checksum_Format_Hex, kCallbackName);
    expect(g_byid.calls == 1, "callback called");
    expect(r.empty(), "abort honoured");
    expect_nothing_live("nothing leaked");
}

void control_no_method_base64() {
    u16 r = checksum(Checksum_MD5, Checksum_Format_Base64, u16());
    expect(g_byid.calls == 0 && g_cmd.calls == 0, "no callback");
    expect(r == to_u16("kAFQmDzST7DWlj99KOF/cg=="), "base64 digest returned");
    expect_nothing_live("nothing leaked");
}

/* Contract 1/2: ARRAY_TEXT fills the array via PA_SetStringInArray and must not dispose. */
void control_array_text_transfer() {
    {
        ARRAY_TEXT a;
        a.appendUTF16String((const PA_Unichar *)u"", 0);
        a.appendUTF16String((const PA_Unichar *)u"x", 1);
        a.appendUTF16String((const PA_Unichar *)u"yz", 2);
        PA_Variable arr = PA_CreateVariable(eVK_ArrayUnicode);
        void *params[1] = { &arr };
        a.toParamAtIndex((PackagePtr)params, 1);
        expect(arr.uValue.fArray.fNbElements == 2, "two elements");
        expect(g_strings.size() == 3, "array owns three strings");
        ARRAY_TEXT b;
        b.fromParamAtIndex((PackagePtr)params, 1);
        CUTF16String s; b.copyUTF16StringAtIndex(&s, 2);
        expect(s == CUTF16String((const PA_Unichar *)u"yz"), "borrowed read");
        PA_ClearVariable(&arr);
    }
    expect_nothing_live("array strings released with the array");
}

/* ---- C_PICTURE (BUILT-UNREACHABLE from Hash's command) ---- */

/* a picture held by C_PICTURE; the harness drops its own reference */
void with_picture(const std::function<void(C_PICTURE &)> &f) {
    {
        C_PICTURE pic;
        PA_Picture src = PA_CreatePicture(0, 0);
        pic.setPicture(src);
        PA_DisposePicture(src);
        expect(g_pics.size() == 1, "one picture held");
        f(pic);
    }
}

void defect_picture_fromfile_ownership() {
    {
        C_PICTURE pic;
        CUTF8String path((const uint8_t *)"/hash-synthetic/does-not-exist.png");
        pic.fromFileAtPath(&path);
        expect(g_read_path == to_u16("/hash-synthetic/does-not-exist.png"), "path delivered");
        expect(g_pics.size() == 1, "only the loaded picture is live");
    }
    expect_nothing_live("READ PICTURE FILE parameters and result released");
}

void defect_picture_setbytes_leak() {
    {
        C_PICTURE pic;
        const uint8_t bytes[] = { 1, 2, 3 };
        pic.setBytes(bytes, sizeof bytes);
        expect(g_pics.size() == 1, "only the held picture is live");
    }
    expect_nothing_live("picture created by setBytes released");
}

void defect_picture_createcopy_ownership() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture p = pic.createCopyPNG();
        expect(g_convert_type == to_u16(".png"), "type delivered");
        expect(p == pic.getPicture(), "retained copy returned");
        PA_DisposePicture(p);
    });
    expect_nothing_live("CONVERT PICTURE parameters released");
}

void defect_picture_grayscale_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture p = pic.createGrayScale();
        expect(g_transform_op == 101, "operator delivered");
        PA_DisposePicture(p);
    });
    expect_nothing_live("TRANSFORM PICTURE parameters released");
}

void defect_picture_getsize_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        unsigned int w = 0, h = 0;
        pic.getSize(&w, &h);
        expect(w == 640 && h == 480, "size delivered");
    });
    expect_nothing_live("PICTURE PROPERTIES parameters released");
}

void defect_picture_thumbnail_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture t = pic.createThumbnail(32, 24);
        expect(g_thumb_w == 32 && g_thumb_h == 24, "size delivered");
        expect(t && t != pic.getPicture() && g_pics.count((Pic *)t), "thumbnail handed to the caller");
        PA_DisposePicture(t);
    });
    expect_nothing_live("CREATE THUMBNAIL parameters released");
}

/* Contract 6 control: C_PICTURE parameter/return transfer. */
void control_picture_param_return() {
    PA_Picture in = PA_CreatePicture(0, 0);
    PA_Picture out = PA_CreatePicture(0, 0);
    PA_Picture ret = 0;
    {
        C_PICTURE pic;
        void *params[2] = { &in, &out };
        pic.fromParamAtIndex((PackagePtr)params, 1);
        pic.toParamAtIndex((PackagePtr)params, 2);
        pic.setReturn((sLONG_PTR *)&ret);
        expect(out == in && ret == in, "same picture retained");
    }
    PA_DisposePicture(in);
    PA_DisposePicture(out);
    PA_DisposePicture(ret);
    expect_nothing_live("all references balanced");
}

const std::map<std::string, std::function<void()>> kTests = {
    { "defect_1007_param_owner_leak", defect_1007_param_owner_leak },
    { "control_1007_args_delivered", control_1007_args_delivered },
    { "control_1007_abort", control_1007_abort },
    { "control_byid_args_delivered", control_byid_args_delivered },
    { "control_byid_result_cleared", control_byid_result_cleared },
    { "control_byid_abort", control_byid_abort },
    { "control_no_method_base64", control_no_method_base64 },
    { "control_array_text_transfer", control_array_text_transfer },
    { "defect_picture_fromfile_ownership", defect_picture_fromfile_ownership },
    { "defect_picture_setbytes_leak", defect_picture_setbytes_leak },
    { "defect_picture_createcopy_ownership", defect_picture_createcopy_ownership },
    { "defect_picture_grayscale_owner_leak", defect_picture_grayscale_owner_leak },
    { "defect_picture_getsize_owner_leak", defect_picture_getsize_owner_leak },
    { "defect_picture_thumbnail_owner_leak", defect_picture_thumbnail_owner_leak },
    { "control_picture_param_return", control_picture_param_return },
};

} // namespace

int main(int argc, char **argv) {
    gCall4D = (Call4DProcPtr)engine;
    if(argc == 2 && std::string(argv[1]) == "--list") {
        for(auto &t : kTests) printf("%s\n", t.first.c_str());
        return 0;
    }
    if(argc != 2 || !kTests.count(argv[1])) { fprintf(stderr, "usage: %s --list | <test>\n", argv[0]); return 2; }
    kTests.at(argv[1])();
    printf("PASS %s\n", argv[1]);
    return 0;
}
