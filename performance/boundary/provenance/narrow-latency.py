"""Rebuild the boundary narrow-read latency tables from saved AXI and router events."""

import csv
from collections import defaultdict, deque
from pathlib import Path
from statistics import mean


ROOT = Path(__file__).resolve().parents[1]
STAGES = (
    "source_ar_to_first_req_ns", "req_first_to_last_ns", "last_req_to_device_ar_ns",
    "device_ar_to_r_ns", "device_r_to_first_rsp_ns", "rsp_first_to_last_ns",
    "last_rsp_to_source_r_ns",
)
SUMMARY = ("load", "source", "hops", "transactions", "request_ns", "service_ns",
           "response_ns", "latency_ns", *STAGES)
DETAIL = ("load", "source", "transaction_index", "address", "source_ar_ps",
          "first_req_ps", "last_req_ps", "device_ar_ps", "device_r_ps",
          "first_rsp_ps", "last_rsp_ps", "source_r_ps")


def read_rows(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def group_router_events(rows):
    paths = defaultdict(deque)
    for row in rows:
        channel = row["channel"]
        if channel == "req":
            assert row["kind"] == "2" and row["dst"] == "15"
            source = int(row["src"])
        else:
            assert channel == "rsp" and row["kind"] == "4" and row["src"] == "15"
            source = int(row["dst"])
        paths[source, channel].append((int(row["time_ps"]), int(row["router"]), int(row["port"])))
    return paths


def take_path(events, start, end, source, dest, hop_count):
    path = []
    while events and events[0][0] <= end:
        path.append(events.popleft())
    assert len(path) == hop_count + 1 and len({router for _, router, _ in path}) == len(path)
    assert path[0][0] >= start and path[0][1] == source and path[-1][1:] == (dest, 0)
    return path


def analyze(run, original, summaries, details, hop_excess):
    load = "full" if run.name == "narrow-full" else "zero"
    devices = defaultdict(deque)
    sources = defaultdict(list)
    rows = sorted(read_rows(run / "tables/transactions.csv"), key=lambda r: int(r["request_ps"]))
    for row in rows:
        assert row["direction"] == "read" and row["beats"] == "1" and row["useful_bytes"] == "8"
        if row["role"] == "device":
            assert row["endpoint"] == "15"
            devices[row["addr"]].append(row)
        else:
            assert row["role"] == "source" and row["phase"] == "1"
            sources[int(row["endpoint"])].append(row)

    paths = group_router_events(read_rows(run / "tables/channel-events.csv"))
    for source, transactions in sorted(sources.items()):
        hop_count = 6 - source % 4 - source // 4
        samples = []
        previous_end = -1
        for index, txn in enumerate(transactions):
            start, end = int(txn["request_ps"]), int(txn["completion_ps"])
            assert previous_end < start and end - start == int(txn["latency_ps"])
            previous_end = end
            device = devices[txn["addr"]].popleft()
            ar, r = int(device["request_ps"]), int(device["completion_ps"])
            req = take_path(paths[source, "req"], start, end, source, 15, hop_count)
            rsp = take_path(paths[source, "rsp"], start, end, 15, source, hop_count)
            times = [start, req[0][0], req[-1][0], ar, r, rsp[0][0], rsp[-1][0], end]
            assert times == sorted(times)
            details.append([load, source, index, txn["addr"], *times])
            stages = [(b - a) / 1000 for a, b in zip(times, times[1:])]
            samples.append([(ar - start) / 1000, (r - ar) / 1000, (end - r) / 1000,
                            (end - start) / 1000, *stages])
            for earlier, later in zip(req, req[1:]):
                # One cycle per hop in the isolated run on this 1 GHz mesh.
                hop_excess[load, later[1], later[2]] += (later[0] - earlier[0]) / 1000 - 1
        averages = [mean(column) for column in zip(*samples)]
        assert len(samples) == 100 and abs(averages[3] - original[load, source]) < 1e-9
        summaries.append([load, source, hop_count, len(samples), *averages])

    assert not any(devices.values()) and not any(paths.values())


def write_table(name, fields, rows):
    path = ROOT / "tables" / (name + ".csv")
    with path.open("w", newline="") as stream:
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerow(fields)
        writer.writerows(sorted(rows, key=lambda row: (row[0] != "zero", *row[1:3])))


def main():
    original = {(row["load"], int(row["source"])): float(row["mean_latency_ns"])
                for row in read_rows(ROOT / "tables/sources.csv") if row["kind"] == "narrow"}
    summaries, details = [], []
    hop_excess = defaultdict(float)
    for run in sorted((ROOT / "results").glob("narrow-*")):
        analyze(run, original, summaries, details, hop_excess)
    assert len(summaries) == 30 and len(details) == 3000
    write_table("narrow-latency-breakdown", SUMMARY, summaries)
    write_table("narrow-latency-transactions", DETAIL, details)
    # Port 0 is the local output on router 15.
    count = sum(row[0] == "full" for row in details)
    excess = (hop_excess["full", 15, 0] - hop_excess["zero", 15, 0]) / count
    print(f"Mean additional request time on the final hop: {excess:.3f} ns")


if __name__ == "__main__":
    main()
