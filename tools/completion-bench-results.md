# Completion benchmark

Times in milliseconds; p50 / p95.

| Workload | Mode | n | First popup | Fresh suggestions | Next page | 20 pages | Max timer gap |
|---|---|---:|---:|---:|---:|---:|---:|
| cold | sync | 2 | 1241.3 / 1389.2 | 1241.5 / 1389.4 | 1.0 / 1.0 | 50.3 / 52.0 | 257.0 / 269.3 |
| cold | lazy-cold | 2 | 1251.9 / 1496.6 | 1251.9 / 1496.6 | 1.8 / 2.7 | 19.6 / 21.4 | 91.8 / 101.5 |
| cold | lazy | 2 | 707.1 / 837.0 | 707.1 / 837.0 | 1.2 / 1.4 | 19.1 / 19.3 | 62.1 / 64.3 |
| initial | sync | 24 | 516.6 / 1353.6 | 517.4 / 1354.2 | 0.9 / 8.5 | 35.2 / 285.8 | 93.8 / 304.6 |
| initial | lazy-cold | 24 | 293.7 / 570.8 | 293.7 / 570.8 | 1.3 / 28.6 | 19.6 / 50.8 | 35.5 / 60.9 |
| initial | lazy | 24 | 345.9 / 826.2 | 345.9 / 826.2 | 1.5 / 33.3 | 19.7 / 51.7 | 40.8 / 65.2 |
| update | sync | 42 | 266.7 / 1462.0 | 266.8 / 1462.9 | 1.0 / 18.2 | 55.0 / 383.8 | 99.2 / 513.5 |
| update | lazy-cold | 42 | 6.2 / 111.8 | 114.2 / 524.4 | 0.9 / 26.3 | 46.5 / 55.5 | 31.2 / 59.2 |
| update | lazy | 42 | 6.0 / 151.1 | 150.1 / 621.9 | 1.0 / 29.8 | 48.0 / 65.3 | 31.5 / 62.2 |
| typing | sync | 18 | 787.5 / 7158.8 | 787.5 / 7158.8 | 1.2 / 45.5 | 22.6 / 390.2 | 354.4 / 3841.8 |
| typing | lazy-cold | 18 | 301.0 / 369.8 | 301.0 / 369.8 | 0.9 / 1.2 | 12.1 / 51.3 | 30.0 / 53.2 |
| typing | lazy | 18 | 350.2 / 628.8 | 350.2 / 628.8 | 1.1 / 8.0 | 12.7 / 259.5 | 37.1 / 172.2 |

| Prefix | Mode | n | First popup | Fresh | Next page | Candidates | Reply items |
|---|---|---:|---:|---:|---:|---:|---:|
| `Bench` | sync | 6 | 912.0 / 959.9 | 912.2 / 960.0 | 1.0 / 1.1 | 21002.0 / 21002.0 | 21002.0 / 21002.0 |
| `Bench` | lazy-cold | 6 | 528.4 / 849.7 | 528.4 / 849.7 | 1.1 / 29.4 | 21002.0 / 21002.0 | 21002.0 / 21002.0 |
| `Bench` | lazy | 6 | 667.2 / 826.2 | 667.2 / 826.2 | 32.0 / 34.3 | 21002.0 / 21002.0 | 21002.0 / 21002.0 |
| `BenchF` | sync | 6 | 907.8 / 1462.0 | 907.9 / 1462.9 | 1.1 / 7.8 | 20000.0 / 20000.0 | 20000.0 / 20000.0 |
| `BenchF` | lazy-cold | 6 | 5.3 / 6.3 | 446.3 / 832.5 | 0.8 / 0.9 | 20000.0 / 20000.0 | 20000.0 / 20000.0 |
| `BenchF` | lazy | 6 | 5.7 / 6.0 | 603.3 / 890.6 | 0.9 / 1.1 | 20000.0 / 20000.0 | 20000.0 / 20000.0 |
| `BenchFunc19` | sync | 6 | 350.2 / 816.8 | 350.3 / 817.3 | 1.0 / 91.1 | 3738.0 / 3738.0 | 3738.0 / 3738.0 |
| `BenchFunc19` | lazy-cold | 6 | 6.1 / 8.4 | 145.8 / 160.7 | 0.9 / 1.2 | 3738.0 / 3738.0 | 3738.0 / 3738.0 |
| `BenchFunc19` | lazy | 6 | 6.3 / 11.6 | 203.1 / 364.3 | 1.1 / 1.4 | 3738.0 / 3738.0 | 3738.0 / 3738.0 |
| `BenchV` | sync | 6 | 202.4 / 452.7 | 202.6 / 454.1 | 1.1 / 13.1 | 1000.0 / 1000.0 | 1000.0 / 1000.0 |
| `BenchV` | lazy-cold | 6 | 91.3 / 97.2 | 91.3 / 97.2 | 1.4 / 1.5 | 1000.0 / 1000.0 | 1000.0 / 1000.0 |
| `BenchV` | lazy | 6 | 127.5 / 137.6 | 127.5 / 137.6 | 1.2 / 2.3 | 1000.0 / 1000.0 | 1000.0 / 1000.0 |
| `obj.` | sync | 6 | 86.8 / 104.0 | 87.1 / 104.2 | 0.9 / 6.4 | 200.0 / 200.0 | 200.0 / 200.0 |
| `obj.` | lazy-cold | 6 | 39.0 / 41.6 | 39.0 / 41.6 | 27.0 / 28.6 | 200.0 / 200.0 | 200.0 / 200.0 |
| `obj.` | lazy | 6 | 62.9 / 127.2 | 62.9 / 127.2 | 1.5 / 2.8 | 200.0 / 200.0 | 200.0 / 200.0 |
| `obj.Field0` | sync | 6 | 64.2 / 77.8 | 64.3 / 78.0 | 0.9 / 18.2 | 100.0 / 100.0 | 100.0 / 100.0 |
| `obj.Field0` | lazy-cold | 6 | 42.2 / 45.9 | 42.2 / 45.9 | 1.5 / 2.4 | 100.0 / 100.0 | 100.0 / 100.0 |
| `obj.Field0` | lazy | 6 | 59.0 / 128.2 | 59.0 / 128.2 | 1.5 / 1.9 | 100.0 / 100.0 | 100.0 / 100.0 |
| `catalog.` | sync | 6 | 759.4 / 1427.8 | 759.5 / 1429.0 | 0.7 / 8.5 | 21003.0 / 21003.0 | 21003.0 / 21003.0 |
| `catalog.` | lazy-cold | 6 | 499.1 / 519.3 | 499.1 / 519.3 | 0.9 / 1.0 | 21003.0 / 21003.0 | 21003.0 / 21003.0 |
| `catalog.` | lazy | 6 | 681.8 / 842.2 | 681.8 / 842.2 | 1.0 / 2.0 | 21003.0 / 21003.0 | 21003.0 / 21003.0 |

Typing "Func199" at 30 ms intervals into the open "Bench" popup:
- sync: key lag 182.7 / 404.5 (n=42); no fresh popup within 5 s: 0/6; fresh after last key 391.5 / 476.7; max timer gap 344.2 / 354.1
- lazy-cold: key lag 4.5 / 29.9 (n=42); no fresh popup within 5 s: 0/6; fresh after last key 121.0 / 123.1; max timer gap 29.7 / 41.3
- lazy: key lag 5.0 / 33.4 (n=42); no fresh popup within 5 s: 0/6; fresh after last key 156.1 / 174.1; max timer gap 31.9 / 34.4

Typing "Func19999" at 30 ms intervals into the open "Bench" popup:
- sync: key lag 202.9 / 1136.0 (n=54); no fresh popup within 5 s: 0/6; fresh after last key 520.6 / 2810.7; max timer gap 346.0 / 1795.0
- lazy-cold: key lag 6.2 / 29.3 (n=54); no fresh popup within 5 s: 0/6; fresh after last key 108.7 / 129.8; max timer gap 36.7 / 53.2
- lazy: key lag 6.8 / 136.7 (n=54); no fresh popup within 5 s: 0/6; fresh after last key 174.2 / 388.8; max timer gap 38.8 / 172.2

Typing "ZZZ" at 30 ms intervals into the open "Bench" popup:
- sync: key lag 1301.1 / 7098.6 (n=18); no fresh popup within 5 s: 0/6; fresh after last key 1438.8 / 7098.8; max timer gap 762.4 / 3841.8
- lazy-cold: key lag 16.6 / 43.1 (n=18); no fresh popup within 5 s: 0/6; fresh after last key 88.7 / 107.9; max timer gap 27.7 / 29.9
- lazy: key lag 43.3 / 209.2 (n=18); no fresh popup within 5 s: 0/6; fresh after last key 174.9 / 397.6; max timer gap 53.0 / 153.3

Warmup (lazy only, before the user-visible cold row): request 397.5 / 501.1, reply items 0.0 / 0.0, max timer gap 76.0 / 101.6; n=2

```json
{
  "go": "go version go1.23.3 darwin/arm64",
  "gopls": "golang.org/x/tools/gopls v0.21.1",
  "emacs": "31.1",
  "platform": "macOS-26.7.2-arm64-arm-64bit-Mach-O",
  "variables": 1000,
  "functions": 20000,
  "rounds": 3,
  "order": [
    "sync",
    "lazy-cold",
    "lazy",
    "lazy",
    "lazy-cold",
    "sync"
  ]
}
```
