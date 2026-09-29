"""File-master parsers retained from the original pattern tests."""
from pathlib import Path

def _parse_write(path):
    """Parse a write.txt back into txns. Mirrors axi_file_master.parse_write field order."""
    toks = open(path).read().split("\n")
    it = iter([t for t in toks if t != ""])
    txns = []
    while True:
        try:
            axid = int(next(it))
        except StopIteration:
            break
        addr = int(next(it), 16)
        length = int(next(it)); size = int(next(it)); burst = int(next(it))
        for _ in range(6):  # lock cache prot qos region atop
            next(it)
        next(it)            # user
        beats = [next(it) for _ in range(length + 1)]
        txns.append({"id": axid, "addr": addr, "len": length, "size": size,
                     "burst": burst, "beats": beats})
    return txns

def _parse_read(path):
    toks = [t for t in Path(path).read_text().splitlines() if t]
    txns = []
    for i in range(0, len(toks), 11):
        fields = toks[i:i + 11]
        assert len(fields) == 11
        txns.append({"id": int(fields[0]), "addr": int(fields[1], 16),
                     "len": int(fields[2]), "size": int(fields[3]),
                     "burst": int(fields[4])})
    return txns
