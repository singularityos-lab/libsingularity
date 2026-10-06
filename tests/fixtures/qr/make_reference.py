import ctypes, sys
lib = ctypes.CDLL("libqrencode.so.4")
class QRcode(ctypes.Structure):
    _fields_ = [("version", ctypes.c_int), ("width", ctypes.c_int), ("data", ctypes.POINTER(ctypes.c_ubyte))]
lib.QRcode_encodeData.restype = ctypes.POINTER(QRcode)
lib.QRcode_encodeData.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
lib.QRcode_free.argtypes = [ctypes.POINTER(QRcode)]
LEVELS = "LMQH"
def pattern(n, mul, add):
    return bytes(((i * mul + add) % 256) for i in range(n))
cases = [
    (b"HELLO WORLD", "L"), (b"HELLO WORLD", "M"), (b"HELLO WORLD", "Q"), (b"HELLO WORLD", "H"),
    (b"https://www.example.org/decoder?x=1", "M"),
    (b"WIFI:T:WPA;S:My\\;Home;P:p\\:a\\,ss\\\\;;", "Q"),
    ("Caffè ☕ Ünïcödé".encode("utf-8"), "H"),
    (pattern(100, 7, 3), "M"),
    (pattern(150, 13, 1), "L"),
    (pattern(300, 29, 5), "Q"),
    (pattern(1000, 31, 17), "H"),
    (pattern(2953, 37, 11), "L"),
    (pattern(1273, 41, 0), "H"),
]
out = sys.stdout
for data, lvl in cases:
    q = lib.QRcode_encodeData(len(data), data, 0, LEVELS.index(lvl))
    w = q.contents.width
    m = [[q.contents.data[y * w + x] & 1 for x in range(w)] for y in range(w)]
    pos = [(8, i) for i in range(6)] + [(8, 7), (8, 8), (7, 8)] + [(14 - i, 8) for i in range(9, 15)]
    v = 0
    for i, (x, y) in enumerate(pos):
        v |= m[y][x] << i
    v ^= 0x5412
    mask = (v >> 10) & 7
    out.write("%s %d %d %s\n" % (lvl, q.contents.version, mask, data.hex()))
    for row in m:
        out.write("".join(str(b) for b in row) + "\n")
    out.write("\n")
    lib.QRcode_free(q)
