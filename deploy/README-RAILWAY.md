# X Router — Railway Deployment Kit

Repo ini berisi source **X Router** (fork dari [johsua092-ui/xrouter](https://github.com/johsua092-ui/xrouter), lisensi MIT) plus script installer untuk [Railway](https://railway.com).

- Source aplikasi ada di root repo (`Dockerfile`, `custom-server.js`, `src/`, `open-sse/`, dst).
- Installer ada di [`deploy/install-xrouter-railway.sh`](deploy/install-xrouter-railway.sh).
- Script membuat service Railway dari repo GitHub ini, jadi setiap push ke `main` otomatis redeploy.

## Prasyarat

1. Akun Railway (Trial/Hobby/Pro). Build Next.js butuh RAM; jangan pakai container 512 MB.
2. Railway CLI — script menginstall otomatis kalau belum ada.
3. **Railway GitHub App** terpasang dan diberi akses ke repo `yanndevgbut/xrouter-railway`
   (repo private). Install di <https://github.com/apps/railway-app/installations/new>.
4. Bash, `curl`, `git`. `openssl`/`python3`/`node` salah satu, untuk generate secret.

## Cara pakai

```bash
git clone https://github.com/yanndevgbut/xrouter-railway.git
cd xrouter-railway

# Wizard (login Railway, buat project/service/volume/domain, set env)
bash deploy/install-xrouter-railway.sh
```

Di tengah proses script berhenti dan meminta Anda mengisi **`INITIAL_PASSWORD`** di
Railway → Variables. Itu memang disengaja: password tidak dibuat otomatis dan tidak
pernah masuk repo.

Setelah selesai:

```
Dashboard : https://<domain>.up.railway.app/login
API OpenAI: https://<domain>.up.railway.app/v1
API Claude: https://<domain>.up.railway.app
```

Login memakai password yang Anda isi di `INITIAL_PASSWORD` (tanpa username).

### Opsi

| Flag | Fungsi |
|---|---|
| `--repo owner/repo` | Repo sumber (default `yanndevgbut/xrouter-railway`) |
| `--branch name` | Branch deploy (default `main`) |
| `--project name` | Nama project Railway (default `xrouter`) |
| `--service name` | Nama service Railway (default `xrouter`) |
| `--workspace id\|name` | Untuk akun dengan beberapa workspace |
| `--domain host` | Custom domain, bukan `*.up.railway.app` |
| `--local` | Deploy dari source lokal (`railway up`), bukan GitHub |
| `--update` | `railway redeploy --from-source`, ambil commit terbaru |
| `--no-wait` | Selesai setelah deploy dijadwalkan |
| `-y, --yes` | Non-interaktif (untuk CI) |
| `--dry-run` | Cetak perintah tanpa mengubah apa pun |
| `-h, --help` | Bantuan |

Contoh non-interaktif:

```bash
RAILWAY_API_TOKEN=... INITIAL_PASSWORD='...' \
  bash deploy/install-xrouter-railway.sh --workspace "My Team" -y
```

`INITIAL_PASSWORD` hanya dibaca dari environment. Kalau tidak di-set, isi manual di
dashboard seperti langkah di atas.

## Environment variables yang dipasang

| Variable | Nilai |
|---|---|
| `NODE_ENV` | `production` |
| `PORT` | `20128` |
| `DATA_DIR` | `/app/data` |
| `JWT_SECRET` | random 64 hex (dibuat sekali, tidak dirotasi saat rerun) |
| `API_KEY_SECRET` | random 64 hex |
| `MACHINE_ID_SALT` | random 64 hex |
| `AUTH_COOKIE_SECURE` | `true` |
| `BASE_URL` / `PUBLIC_BASE_URL` / `NEXT_PUBLIC_BASE_URL` | `https://<domain>` |
| `NODE_OPTIONS` | `--expose-gc --max-old-space-size=256 --dns-result-order=ipv4first` |
| `NEXT_TELEMETRY_DISABLED` | `1` |
| `ENABLE_REQUEST_LOGS` | `false` |
| `OBSERVABILITY_ENABLED` | `true` |
| `REQUIRE_API_KEY` | `false` |

`PASSWORD` sengaja tidak termasuk — lihat bagian di atas.

## Volume & data

Volume Railway dipasang di `/app/data` (SQLite WAL, JWT secret, revoked sessions).
Tanpa volume, semua data hilang setiap deploy. Batas Free plan 0.5 GB; cukup untuk
ribuan request metadata.

Backup / restore:

```bash
railway volume files download / ./xrouter-data-backup
railway volume files upload ./xrouter-data-backup /
```

## Update

```bash
git pull
bash deploy/install-xrouter-railway.sh --update
```

Atau cukup push ke `main`: service Railway terhubung ke repo ini dan auto-deploy.
Kalau ingin auto-deploy dari commit Anda sendiri, fork/ubah `--repo` ke repo Anda.

## Troubleshooting

**`railway add --repo` gagal / repo tidak muncul**
Railway GitHub App belum punya akses ke repo private ini. Install di
<https://github.com/apps/railway-app/installations/new>, beri akses ke
`xrouter-railway`, lalu ulangi. Alternatif: jalankan `--local` dari dalam clone repo.

**Build gagal / OOM**
Build `npm install` + `next build` butuh beberapa GB RAM. Naikkan resource build di
Railway, lalu redeploy. Lihat `railway logs --build`.

**502 / Bad Gateway**
Pastikan domain mengarah ke port `20128` (`railway domain update <domain> --port 20128`),
dan variable `PORT=20128` ada.

**Login ditolak: "default password only works from the machine running..."**
`INITIAL_PASSWORD` belum di-set. Tambahkan di Railway → Variables, tunggu redeploy,
lalu login. Setelah login pertama, ganti password lewat dashboard (nilai
`INITIAL_PASSWORD` tidak lagi dipakai).

**Provider tertentu gagal connect (`fetch failed`)**
Railway punya isu route IPv6 untuk sebagian host. `NODE_OPTIONS` sudah memakai
`--dns-result-order=ipv4first`; kalau masih gagal, cek log service.

**Dependency berubah sendiri**
Repo upstream tidak menyertakan `package-lock.json`, jadi `npm install` mengambil
versi terbaru yang cocok. Kalau butuh reproducible build, commit lockfile sendiri.

## Keamanan

- Jangan commit token, `.env`, atau isi `data/`. Repo ini private, tapi tetap jaga.
- Setelah instalasi, rotate Railway token / GitHub PAT yang pernah dipakai.
- `INITIAL_PASSWORD` tidak boleh sama dengan password akun lain.
- Akses dashboard = akses ke semua provider key; batasi anggota workspace Railway.

## Lisensi

Source X Router: MIT © X Router Contributors (johsua092-ui, decolua, naummi, BvsshXyz).
Script installer di `deploy/` mengikuti lisensi yang sama.
