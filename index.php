<?php
// Load stored credentials for pre-populating the form
$mt_creds = ['host' => '', 'login' => '', 'pass' => ''];
$ac_creds = ['host' => '', 'login' => '', 'pass' => '', 'port' => '9082', 'proto' => 'https'];

$creds_dir = '/var/www/.config/airos-to-dhcp';

// MikroTik creds: "HOST LOGIN PASS" per line
$mt_file = "$creds_dir/mikrotik_creds";
if (file_exists($mt_file)) {
    $lines = file($mt_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if (!empty($lines)) {
        // Use the last (most recent) entry
        $parts = preg_split('/\s+/', end($lines));
        if (count($parts) >= 3) {
            $mt_creds = ['host' => $parts[0], 'login' => $parts[1], 'pass' => $parts[2]];
        }
    }
}

// AirControl2 creds: "HOST LOGIN PASS PORT PROTO" per line
$ac_file = "$creds_dir/aircontrol_creds";
if (file_exists($ac_file)) {
    $lines = file($ac_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if (!empty($lines)) {
        $parts = preg_split('/\s+/', end($lines));
        if (count($parts) >= 3) {
            $ac_creds['host'] = $parts[0];
            $ac_creds['login'] = $parts[1];
            $ac_creds['pass'] = $parts[2];
            if (!empty($parts[3])) $ac_creds['port'] = $parts[3];
            if (!empty($parts[4])) $ac_creds['proto'] = $parts[4];
        }
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AirOS to DHCP Converter</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #1a1a2e; color: #eee; padding: 20px; }
h1 { color: #00d4ff; margin-bottom: 20px; font-size: 1.5em; }
.container { max-width: 900px; margin: 0 auto; }
.section { background: #16213e; border-radius: 8px; padding: 20px; margin-bottom: 15px; }
.section h2 { color: #00d4ff; font-size: 1.1em; margin-bottom: 12px; }
label { display: block; margin-bottom: 4px; color: #aaa; font-size: 0.9em; }
input, textarea { width: 100%; padding: 8px 10px; border: 1px solid #333; border-radius: 4px;
    background: #0f3460; color: #eee; font-family: monospace; font-size: 0.9em; margin-bottom: 10px; }
textarea { height: 100px; resize: vertical; }
.row { display: flex; gap: 10px; }
.row > div { flex: 1; }
button { padding: 10px 24px; border: none; border-radius: 4px; cursor: pointer;
    font-size: 1em; font-weight: bold; }
#btn-start { background: #00d4ff; color: #1a1a2e; }
#btn-start:hover { background: #00b8d9; }
#btn-start:disabled { background: #555; color: #888; cursor: not-allowed; }
#btn-retry { background: #e94560; color: #fff; display: none; margin-left: 10px; }
#btn-retry:hover { background: #c73e54; }
.ip-entry { padding: 8px 12px; margin: 4px 0; border-radius: 4px; font-family: monospace;
    font-size: 0.9em; background: #0f3460; display: flex; justify-content: space-between;
    align-items: center; }
.ip-entry.success { background: #1b5e20; }
.ip-entry.fail { background: #b71c1c; }
.ip-entry.running { background: #e65100; }
.ip-entry .status { font-size: 0.85em; color: #ccc; max-width: 60%; text-align: right; }
.ip-entry.success .status { color: #a5d6a7; }
.ip-entry.fail .status { color: #ef9a9a; }
#global-status { padding: 10px; margin-bottom: 10px; border-radius: 4px; display: none;
    font-weight: bold; }
#global-status.error { background: #b71c1c; display: block; }
#global-status.info { background: #e65100; display: block; }
.conn-status { font-size: 0.75em; padding: 3px 10px; border-radius: 10px; margin-left: 8px;
    vertical-align: middle; }
.conn-status.ok { background: #1b5e20; color: #a5d6a7; }
.conn-status.fail { background: #b71c1c; color: #ef9a9a; }
.conn-status.testing { background: #e65100; color: #ffcc80; }
.btn-test { padding: 8px 16px; background: #0f3460; color: #00d4ff; border: 1px solid #00d4ff;
    border-radius: 4px; cursor: pointer; font-size: 0.85em; margin-bottom: 10px; font-weight: bold; }
.btn-test:hover { background: #1a4a8a; }
.btn-test:disabled { opacity: 0.5; cursor: not-allowed; }
</style>
</head>
<body>
<div class="container">
<h1>AirOS Static-to-DHCP Converter</h1>

<div class="section">
    <h2>AirOS Devices</h2>
    <label for="airos-ips">IP Addresses (one per line, or range like 10.0.0.1-10.0.0.20)</label>
    <textarea id="airos-ips" placeholder="202.174.167.5&#10;202.174.167.6&#10;or 202.174.167.5-202.174.167.20"></textarea>
    <div class="row">
        <div><label for="airos-port">SSH Port</label>
            <input type="text" id="airos-port" value="8022"></div>
        <div><label for="airos-login">Username</label>
            <input type="text" id="airos-login" value="admin"></div>
        <div><label for="airos-pass">Password 1</label>
            <input type="password" id="airos-pass" value="ubnt"></div>
        <div><label for="airos-pass2">Password 2</label>
            <input type="password" id="airos-pass2" placeholder="optional fallback"></div>
    </div>
</div>

<div class="section">
    <h2>MikroTik Router <span id="mt-status" class="conn-status"></span></h2>
    <div class="row">
        <div><label for="mt-ip">IP Address</label>
            <input type="text" id="mt-ip" value="<?= htmlspecialchars($mt_creds['host']) ?>" placeholder="172.17.1.16"></div>
        <div><label for="mt-login">Username (optional)</label>
            <input type="text" id="mt-login" value="<?= htmlspecialchars($mt_creds['login']) ?>" placeholder="stored creds used if blank"></div>
        <div><label for="mt-pass">Password (optional)</label>
            <input type="password" id="mt-pass" value="<?= htmlspecialchars($mt_creds['pass']) ?>" placeholder="stored creds used if blank"></div>
        <div style="flex:0 0 auto; align-self:flex-end;">
            <button type="button" class="btn-test" id="btn-test-mt">Test</button>
        </div>
    </div>
</div>

<div class="section">
    <h2>AirControl2 Server (optional) <span id="ac-status" class="conn-status"></span></h2>
    <div class="row">
        <div><label for="ac-host">Host / IP</label>
            <input type="text" id="ac-host" value="<?= htmlspecialchars($ac_creds['host']) ?>" placeholder="e.g. 192.168.1.100"></div>
        <div><label for="ac-port">Port</label>
            <input type="text" id="ac-port" value="<?= htmlspecialchars($ac_creds['port']) ?>"></div>
        <div><label for="ac-proto">Protocol</label>
            <input type="text" id="ac-proto" value="<?= htmlspecialchars($ac_creds['proto']) ?>"></div>
        <div style="flex:0 0 auto; align-self:flex-end;">
            <button type="button" class="btn-test" id="btn-test-ac">Test</button>
        </div>
    </div>
    <div class="row">
        <div><label for="ac-login">Username (optional)</label>
            <input type="text" id="ac-login" value="<?= htmlspecialchars($ac_creds['login']) ?>" placeholder="stored creds used if blank"></div>
        <div><label for="ac-pass">Password (optional)</label>
            <input type="password" id="ac-pass" value="<?= htmlspecialchars($ac_creds['pass']) ?>" placeholder="stored creds used if blank"></div>
    </div>
</div>

<div style="margin-bottom: 15px;">
    <button id="btn-start">Start Conversion</button>
    <button id="btn-retry">Retry Failed with New Credentials</button>
</div>

<div id="global-status"></div>

<div class="section" id="results-section" style="display:none;">
    <h2>Results</h2>
    <div id="results"></div>
</div>
</div>

<script>
let failedIPs = [];

function parseIPs(text) {
    let ips = [];
    let lines = text.trim().split(/[\n,]+/);
    for (let line of lines) {
        line = line.trim();
        if (!line) continue;
        let rangeMatch = line.match(/^(\d+\.\d+\.\d+\.)(\d+)\s*-\s*(?:\d+\.\d+\.\d+\.)?(\d+)$/);
        if (rangeMatch) {
            let prefix = rangeMatch[1];
            let start = parseInt(rangeMatch[2]);
            let end = parseInt(rangeMatch[3]);
            for (let i = start; i <= end; i++) ips.push(prefix + i);
        } else if (/^\d+\.\d+\.\d+\.\d+$/.test(line)) {
            ips.push(line);
        }
    }
    return ips;
}

function entryId(ip) { return 'entry-' + ip.replace(/\./g, '-'); }

function setEntry(ip, cls, statusText) {
    let el = document.getElementById(entryId(ip));
    if (el) {
        el.className = 'ip-entry ' + cls;
        el.querySelector('.status').textContent = statusText;
    }
}

function showStatus(msg, cls) {
    let el = document.getElementById('global-status');
    el.textContent = msg;
    el.className = cls;
}

function hideStatus() {
    document.getElementById('global-status').className = '';
    document.getElementById('global-status').style.display = 'none';
}

async function runBatch(ipList, port, login, pass, mtIp, mtLogin, mtPass) {
    failedIPs = [];
    document.getElementById('btn-start').disabled = true;
    document.getElementById('btn-retry').style.display = 'none';
    document.getElementById('results-section').style.display = 'block';

    let resultsDiv = document.getElementById('results');
    resultsDiv.innerHTML = '';

    for (let ip of ipList) {
        resultsDiv.innerHTML += '<div class="ip-entry" id="' + entryId(ip) + '">' +
            '<span class="ip">' + ip + '</span>' +
            '<span class="status">Pending</span></div>';
    }

    showStatus('Processing ' + ipList.length + ' device(s)...', 'info');

    let commonParams = {
        'airos_port': port,
        'airos_login': login,
        'airos_pass': pass,
        'airos_pass2': document.getElementById('airos-pass2').value,
        'mt_ip': mtIp,
        'mt_login': mtLogin,
        'mt_pass': mtPass,
        'ac_host': document.getElementById('ac-host').value,
        'ac_port': document.getElementById('ac-port').value,
        'ac_proto': document.getElementById('ac-proto').value,
        'ac_login': document.getElementById('ac-login').value,
        'ac_pass': document.getElementById('ac-pass').value
    };

    let successMACs = [];
    let completed = 0;
    const PARALLEL = 5;

    async function processOne(ip) {
        setEntry(ip, 'running', 'Processing...');
        let params = new URLSearchParams({...commonParams, 'airos_ips': ip});

        try {
            let resp = await fetch('run.php?' + params.toString());
            let data = await resp.json();

            if (!data.success && !data.results) {
                setEntry(ip, 'fail', data.message || 'Failed');
                failedIPs.push(ip);
            } else if (data.results && data.results.length > 0) {
                let r = data.results[0];
                if (r.success) {
                    setEntry(ip, 'success', r.message);
                    let macMatch = r.message.match(/MAC=([0-9A-Fa-f:]{17})/);
                    if (macMatch) successMACs.push(macMatch[1]);
                } else {
                    setEntry(ip, 'fail', r.message);
                    failedIPs.push(ip);
                }
            } else {
                setEntry(ip, 'fail', 'No result returned');
                failedIPs.push(ip);
            }
        } catch (e) {
            setEntry(ip, 'fail', 'Request error: ' + e.message);
            failedIPs.push(ip);
        }

        completed++;
        showStatus('Processed ' + completed + '/' + ipList.length + ' device(s)...', 'info');
    }

    // Process in chunks of PARALLEL with staggered starts
    for (let i = 0; i < ipList.length; i += PARALLEL) {
        let chunk = ipList.slice(i, i + PARALLEL);
        let promises = [];
        for (let j = 0; j < chunk.length; j++) {
            // Stagger each by 10 seconds within the chunk
            let delay = j * 10000;
            promises.push(new Promise(resolve => setTimeout(resolve, delay)).then(() => processOne(chunk[j])));
        }
        await Promise.all(promises);
    }

    hideStatus();

    // Batch tag all successful MACs in AirControl2
    let acHost = document.getElementById('ac-host').value;
    if (acHost && successMACs.length > 0) {
        showStatus('Tagging ' + successMACs.length + ' device(s) in AirControl2...', 'info');
        let acParams = new URLSearchParams({
            'action': 'tag_ac',
            'macs': successMACs.join(','),
            'ac_host': acHost,
            'ac_port': document.getElementById('ac-port').value,
            'ac_proto': document.getElementById('ac-proto').value,
            'ac_login': document.getElementById('ac-login').value,
            'ac_pass': document.getElementById('ac-pass').value
        });
        try {
            let acResp = await fetch('run.php?' + acParams.toString());
            let acData = await acResp.json();
            // Check for any "not found" results
            if (acData.output) {
                let notFound = (acData.output.match(/not found/gi) || []).length;
                if (notFound > 0) {
                    showStatus(notFound + ' device(s) not found in AirControl2 — {DHCP} not added to description', 'error');
                    // Keep the status visible for a few seconds
                    await new Promise(r => setTimeout(r, 5000));
                }
            }
        } catch (e) { /* AC tagging is best-effort */ }
        hideStatus();
    }

    document.getElementById('btn-start').disabled = false;
    if (failedIPs.length > 0) {
        document.getElementById('btn-retry').style.display = 'inline-block';
    }
}

document.getElementById('btn-start').addEventListener('click', function() {
    let ips = parseIPs(document.getElementById('airos-ips').value);
    if (ips.length === 0) { alert('No valid IPs entered.'); return; }
    let port = document.getElementById('airos-port').value || '22';
    let login = document.getElementById('airos-login').value;
    let pass = document.getElementById('airos-pass').value;
    let mtIp = document.getElementById('mt-ip').value;
    if (!login || !pass) { alert('AirOS username and password required.'); return; }
    if (!mtIp) { alert('MikroTik IP required.'); return; }
    runBatch(ips, port, login, pass, mtIp,
        document.getElementById('mt-login').value,
        document.getElementById('mt-pass').value);
});

document.getElementById('btn-retry').addEventListener('click', function() {
    if (failedIPs.length === 0) return;
    let port = document.getElementById('airos-port').value || '22';
    let login = document.getElementById('airos-login').value;
    let pass = document.getElementById('airos-pass').value;
    let mtIp = document.getElementById('mt-ip').value;
    if (!login || !pass) { alert('Update AirOS credentials above, then click Retry.'); return; }
    runBatch([...failedIPs], port, login, pass, mtIp,
        document.getElementById('mt-login').value,
        document.getElementById('mt-pass').value);
});
// ── Connection testing ────────────────────────────────────────────
function setConnStatus(id, cls, text) {
    let el = document.getElementById(id);
    el.className = 'conn-status ' + cls;
    el.textContent = text;
}

async function testMikroTik() {
    let ip = document.getElementById('mt-ip').value;
    if (!ip) { setConnStatus('mt-status', '', ''); return; }

    setConnStatus('mt-status', 'testing', 'testing...');
    document.getElementById('btn-test-mt').disabled = true;

    let params = new URLSearchParams({
        'action': 'test_mt',
        'mt_ip': ip,
        'mt_login': document.getElementById('mt-login').value,
        'mt_pass': document.getElementById('mt-pass').value
    });

    try {
        let resp = await fetch('run.php?' + params.toString());
        let data = await resp.json();
        if (data.success) {
            let label = 'Connected';
            if (data.identity) label += ' — ' + data.identity;
            setConnStatus('mt-status', 'ok', label);
        } else {
            setConnStatus('mt-status', 'fail', 'Failed');
        }
    } catch (e) {
        setConnStatus('mt-status', 'fail', 'Error');
    }
    document.getElementById('btn-test-mt').disabled = false;
}

async function testAirControl() {
    let host = document.getElementById('ac-host').value;
    if (!host) { setConnStatus('ac-status', '', ''); return; }

    setConnStatus('ac-status', 'testing', 'testing...');
    document.getElementById('btn-test-ac').disabled = true;

    let params = new URLSearchParams({
        'action': 'test_ac',
        'ac_host': host,
        'ac_port': document.getElementById('ac-port').value,
        'ac_proto': document.getElementById('ac-proto').value,
        'ac_login': document.getElementById('ac-login').value,
        'ac_pass': document.getElementById('ac-pass').value
    });

    try {
        let resp = await fetch('run.php?' + params.toString());
        let data = await resp.json();
        if (data.success) {
            setConnStatus('ac-status', 'ok', 'Connected');
        } else {
            setConnStatus('ac-status', 'fail', 'Failed');
        }
    } catch (e) {
        setConnStatus('ac-status', 'fail', 'Error');
    }
    document.getElementById('btn-test-ac').disabled = false;
}

document.getElementById('btn-test-mt').addEventListener('click', testMikroTik);
document.getElementById('btn-test-ac').addEventListener('click', testAirControl);

// Auto-test on page load if credentials are pre-filled
window.addEventListener('load', function() {
    // Restore saved AirOS credentials from localStorage
    let fields = ['airos-port', 'airos-login', 'airos-pass', 'airos-pass2'];
    for (let f of fields) {
        let saved = localStorage.getItem('dhcp_' + f);
        if (saved) document.getElementById(f).value = saved;
    }

    if (document.getElementById('mt-ip').value) testMikroTik();
    if (document.getElementById('ac-host').value) testAirControl();
});

// Save AirOS credentials to localStorage on change
['airos-port', 'airos-login', 'airos-pass', 'airos-pass2'].forEach(function(f) {
    document.getElementById(f).addEventListener('change', function() {
        localStorage.setItem('dhcp_' + f, this.value);
    });
});
</script>
</body>
</html>
