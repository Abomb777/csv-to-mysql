# csv-to-mysql
import csv to mysql


##
```bash
C2S_URL="https://raw.githubusercontent.com/Abomb777/csv-to-mysql/refs/heads/main/csv2sql.sh"; [ ! -f csv2sql.sh ] || ! curl -fsSL "$C2S_URL" | md5sum -c <(md5sum csv2sql.sh | awk '{print $1 "  -"}') --status && wget -qO csv2sql.sh "$C2S_URL"; bash csv2sql.sh -d -u .... args...
```