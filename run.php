<?php
/**
 * run.php - Backend for AirOS-to-DHCP converter
 *
 * Called via AJAX from index.php. Executes convert_to_dhcp.sh and
 * streams back JSON results per IP.
 */

header('Content-Type: application/json');

$action = $_GET['action'] ?? 'convert';
$script = __DIR__ . '/convert_to_dhcp.sh';

function safe($val) {
    return escapeshellarg(trim($val));
}

// Test MikroTik connection only
if ($action === 'test_mt') {
    $mt_ip    = safe($_GET['mt_ip'] ?? '');
    $mt_login = safe($_GET['mt_login'] ?? '');
    $mt_pass  = safe($_GET['mt_pass'] ?? '');

    $cmd = "bash $script --mode test_mt --mt-ip $mt_ip";
    if (!empty(trim($_GET['mt_login'] ?? ''))) $cmd .= " --mt-login $mt_login";
    if (!empty(trim($_GET['mt_pass'] ?? '')))  $cmd .= " --mt-pass $mt_pass";

    $output = shell_exec("$cmd 2>&1");
    // Extract identity from output (line like "Identity:   name: Snowden")
    $identity = '';
    foreach (explode("\n", $output) as $line) {
        if (preg_match('/name:\s*(.+)/i', $line, $m)) {
            $identity = trim($m[1]);
        }
    }
    // Last line should be JSON
    $lines = array_filter(explode("\n", trim($output)));
    $last = end($lines);
    $json = json_decode($last, true);
    if ($json) {
        if ($identity) $json['identity'] = $identity;
        echo json_encode($json);
    } else {
        echo json_encode(['success' => false, 'message' => $output]);
    }
    exit;
}

// Batch tag MACs in AirControl2
if ($action === 'tag_ac') {
    $ac_script = __DIR__ . '/aircontrol_tag.sh';
    $macs     = safe($_GET['macs'] ?? '');
    $ac_host  = safe($_GET['ac_host'] ?? '');
    $ac_port  = safe($_GET['ac_port'] ?? '9082');
    $ac_proto = safe($_GET['ac_proto'] ?? 'https');
    $ac_login = safe($_GET['ac_login'] ?? '');
    $ac_pass  = safe($_GET['ac_pass'] ?? '');

    $cmd = "bash $ac_script --macs $macs --ac-host $ac_host --ac-port $ac_port --ac-proto $ac_proto";
    if (!empty(trim($_GET['ac_login'] ?? ''))) $cmd .= " --ac-login $ac_login";
    if (!empty(trim($_GET['ac_pass'] ?? '')))  $cmd .= " --ac-pass $ac_pass";

    $output = shell_exec("$cmd 2>&1");
    echo json_encode(['success' => true, 'output' => $output]);
    exit;
}

// Test AirControl2 connection only
if ($action === 'test_ac') {
    $ac_script = __DIR__ . '/aircontrol_tag.sh';
    $ac_host  = safe($_GET['ac_host'] ?? '');
    $ac_port  = safe($_GET['ac_port'] ?? '9082');
    $ac_proto = safe($_GET['ac_proto'] ?? 'https');
    $ac_login = safe($_GET['ac_login'] ?? '');
    $ac_pass  = safe($_GET['ac_pass'] ?? '');

    $cmd = "bash $ac_script --mode test --ac-host $ac_host --ac-port $ac_port --ac-proto $ac_proto";
    if (!empty(trim($_GET['ac_login'] ?? ''))) $cmd .= " --ac-login $ac_login";
    if (!empty(trim($_GET['ac_pass'] ?? '')))  $cmd .= " --ac-pass $ac_pass";

    $output = shell_exec("$cmd 2>&1");
    $lines = array_filter(explode("\n", trim($output)));
    $last = end($lines);
    $json = json_decode($last, true);
    if ($json) {
        echo json_encode($json);
    } else {
        echo json_encode(['success' => false, 'message' => $output]);
    }
    exit;
}

// Full conversion - batch mode
$airos_ips   = trim($_GET['airos_ips'] ?? '');
$airos_port  = safe($_GET['airos_port'] ?? '22');
$airos_login = safe($_GET['airos_login'] ?? '');
$airos_pass  = safe($_GET['airos_pass'] ?? '');
$airos_pass2 = safe($_GET['airos_pass2'] ?? '');
$mt_ip       = safe($_GET['mt_ip'] ?? '');
$mt_login    = safe($_GET['mt_login'] ?? '');
$mt_pass     = safe($_GET['mt_pass'] ?? '');

if (empty($airos_ips) || empty(trim($_GET['mt_ip'] ?? ''))) {
    echo json_encode(['success' => false, 'message' => 'Missing parameters']);
    exit;
}

// Sanitize IP list: replace newlines/spaces with commas
$ip_list = preg_replace('/[\s,]+/', ',', trim($airos_ips));
$ip_list = safe($ip_list);

$cmd = "bash $script --airos-ips $ip_list --airos-port $airos_port"
     . " --airos-login $airos_login --airos-pass $airos_pass"
     . " --mt-ip $mt_ip";

if (!empty(trim($_GET['airos_pass2'] ?? ''))) $cmd .= " --airos-pass2 $airos_pass2";

if (!empty(trim($_GET['mt_login'] ?? ''))) $cmd .= " --mt-login $mt_login";
if (!empty(trim($_GET['mt_pass'] ?? '')))  $cmd .= " --mt-pass $mt_pass";

// AirControl2 params (optional)
$ac_host  = safe($_GET['ac_host'] ?? '');
$ac_port  = safe($_GET['ac_port'] ?? '9081');
$ac_proto = safe($_GET['ac_proto'] ?? 'https');
$ac_login = safe($_GET['ac_login'] ?? '');
$ac_pass  = safe($_GET['ac_pass'] ?? '');

if (!empty(trim($_GET['ac_host'] ?? ''))) {
    $cmd .= " --ac-host $ac_host --ac-port $ac_port --ac-proto $ac_proto";
    if (!empty(trim($_GET['ac_login'] ?? ''))) $cmd .= " --ac-login $ac_login";
    if (!empty(trim($_GET['ac_pass'] ?? '')))  $cmd .= " --ac-pass $ac_pass";
}

$output = shell_exec("$cmd 2>&1");

// Parse RESULT:{json} lines from output
$results = [];
$lines = explode("\n", $output);
foreach ($lines as $line) {
    if (preg_match('/^RESULT:(.+)$/', trim($line), $m)) {
        $r = json_decode($m[1], true);
        if ($r) $results[] = $r;
    }
}

// Check if MikroTik failed before any results
if (empty($results) && stripos($output, 'authentication failed') !== false) {
    echo json_encode(['success' => false, 'message' => 'MikroTik authentication failed']);
    exit;
}

echo json_encode(['success' => true, 'results' => $results]);
