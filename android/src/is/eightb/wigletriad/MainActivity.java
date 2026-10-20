package is.eightb.wigletriad;

import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanRecord;
import android.content.BroadcastReceiver;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Color;
import android.graphics.Insets;
import android.net.Uri;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.util.Log;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.webkit.ConsoleMessage;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import org.json.JSONArray;
import org.json.JSONObject;

public class MainActivity extends Activity {
    private static final String TAG = "WigleTriad";
    private WebView webView;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Map<String, JSONObject> bleEndpoints = new ConcurrentHashMap<>();
    private BluetoothLeScanner bleScanner;
    private boolean bleScanning = false;
    private BroadcastReceiver wifiScanReceiver;
    private long lastWifiScanTriggerMs = 0L;
    private long lastBridgeNotifyMs = 0L;

    private final ScanCallback bleScanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, android.bluetooth.le.ScanResult result) {
            recordBleResult(result);
        }

        @Override
        public void onBatchScanResults(List<android.bluetooth.le.ScanResult> results) {
            if (results != null) {
                for (android.bluetooth.le.ScanResult r : results) {
                    recordBleResult(r);
                }
            }
        }
    };

    private void recordBleResult(android.bluetooth.le.ScanResult result) {
        if (result == null || result.getDevice() == null) return;
        try {
            BluetoothDevice dev = result.getDevice();
            String addr = dev.getAddress();
            if (addr == null || addr.isEmpty()) return;
            String bssid = addr.toUpperCase();
            String name = null;
            ScanRecord rec = result.getScanRecord();
            if (rec != null) {
                name = rec.getDeviceName();
            }
            if ((name == null || name.isEmpty())) {
                try { name = dev.getName(); } catch (SecurityException ignored) {}
            }
            if (name == null || name.isEmpty()) {
                String compact = bssid.replace(":", "");
                name = "BLE-" + (compact.length() >= 6 ? compact.substring(compact.length() - 6) : compact);
            }
            JSONObject o = new JSONObject();
            o.put("node", "ANDROID:MEDUSA");
            o.put("bssid", bssid);
            o.put("ssid", name);
            o.put("auth", "[BLE]");
            o.put("channel", 37);
            o.put("band", "BLE");
            o.put("type", "BLE");
            o.put("rssi", result.getRssi());
            bleEndpoints.put(bssid, o);
        } catch (Throwable ignored) {}
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(TAG, "MainActivity onCreate: WigleTriad v2.0.0+ultra-omni-evolve · Kawaii Chiro-chan ^^ · Mozart: Lacrimosa · Boldog Még · ALEX|qMom");
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        Window w = getWindow();
        if (w != null) {
            w.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
            w.setStatusBarColor(Color.parseColor("#0B0914"));
            w.setNavigationBarColor(Color.parseColor("#0B0914"));
        }

        WebView.setWebContentsDebuggingEnabled(true);
        webView = new WebView(this);
        webView.setBackgroundColor(Color.parseColor("#0B0914"));
        if (Build.VERSION.SDK_INT >= 20) {
            webView.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
                @Override
                public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                    if (Build.VERSION.SDK_INT >= 30) {
                        Insets sys = insets.getInsets(
                            WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout()
                        );
                        v.setPadding(sys.left, sys.top, sys.right, sys.bottom);
                    } else {
                        v.setPadding(
                            insets.getSystemWindowInsetLeft(),
                            insets.getSystemWindowInsetTop(),
                            insets.getSystemWindowInsetRight(),
                            insets.getSystemWindowInsetBottom()
                        );
                    }
                    return insets;
                }
            });
        }

        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        s.setAllowFileAccessFromFileURLs(true);
        s.setAllowUniversalAccessFromFileURLs(true);
        s.setMediaPlaybackRequiresUserGesture(false);

        requestNeededPermissions();
        registerWifiReceiver();
        startBleScanSafe();

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage cm) {
                if (cm != null) {
                    Log.i(TAG, "JSConsole [" + cm.messageLevel() + "]: " + cm.message() + " (" + cm.sourceId() + ":" + cm.lineNumber() + ")");
                }
                return super.onConsoleMessage(cm);
            }
        });
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                if (url == null || (!url.startsWith("https://esp32.vaked.dev") && !url.startsWith("file:///android_asset/"))) {
                    return;
                }
                Log.i(TAG, "onPageFinished: " + url);
                mainHandler.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        notifyWebViewBridge();
                    }
                }, 1800);
                verifyDomState();
            }
        });
        webView.addJavascriptInterface(new AndroidWigleBridge(this), "AndroidWigleBridge");

        setContentView(webView);
        try {
            java.io.InputStream is = getAssets().open("index.html");
            byte[] buf = new byte[is.available()];
            int read = 0;
            while (read < buf.length) {
                int r = is.read(buf, read, buf.length - read);
                if (r <= 0) break;
                read += r;
            }
            is.close();
            String html = new String(buf, 0, read, StandardCharsets.UTF_8);
            webView.loadDataWithBaseURL("https://esp32.vaked.dev/", html, "text/html", "UTF-8", "https://esp32.vaked.dev/");
        } catch (Throwable e) {
            webView.loadUrl("file:///android_asset/index.html");
        }
    }

    private void requestNeededPermissions() {
        if (Build.VERSION.SDK_INT < 23) return;
        List<String> needed = new ArrayList<>();
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            needed.add(android.Manifest.permission.ACCESS_FINE_LOCATION);
        }
        if (checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            needed.add(android.Manifest.permission.ACCESS_COARSE_LOCATION);
        }
        if (Build.VERSION.SDK_INT >= 31) {
            if (checkSelfPermission("android.permission.BLUETOOTH_SCAN")
                    != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                needed.add("android.permission.BLUETOOTH_SCAN");
            }
            if (checkSelfPermission("android.permission.BLUETOOTH_CONNECT")
                    != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                needed.add("android.permission.BLUETOOTH_CONNECT");
            }
        }
        if (!needed.isEmpty()) {
            requestPermissions(needed.toArray(new String[0]), 808);
        }
    }

    private void registerWifiReceiver() {
        try {
            wifiScanReceiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    boolean updated = intent != null && intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, false);
                    long now = System.currentTimeMillis();
                    if (updated && (now - lastBridgeNotifyMs > 4000L)) {
                        lastBridgeNotifyMs = now;
                        notifyWebViewBridge();
                    }
                }
            };
            IntentFilter filter = new IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION);
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(wifiScanReceiver, filter, Context.RECEIVER_EXPORTED);
            } else {
                registerReceiver(wifiScanReceiver, filter);
            }
        } catch (Throwable ignored) {}
    }

    private void startBleScanSafe() {
        try {
            BluetoothManager bm = (BluetoothManager) getSystemService(Context.BLUETOOTH_SERVICE);
            BluetoothAdapter adapter = bm != null ? bm.getAdapter() : BluetoothAdapter.getDefaultAdapter();
            if (adapter != null && adapter.isEnabled()) {
                try {
                    Set<BluetoothDevice> bonded = adapter.getBondedDevices();
                    if (bonded != null) {
                        for (BluetoothDevice dev : bonded) {
                            if (dev == null || dev.getAddress() == null) continue;
                            String bssid = dev.getAddress().toUpperCase();
                            if (!bleEndpoints.containsKey(bssid)) {
                                String name = dev.getName();
                                JSONObject o = new JSONObject();
                                o.put("node", "ANDROID:MEDUSA");
                                o.put("bssid", bssid);
                                o.put("ssid", (name != null && !name.isEmpty()) ? name : ("BT-" + bssid));
                                o.put("auth", "[BT-CLASSIC][BONDED]");
                                o.put("channel", 0);
                                o.put("band", "BT");
                                o.put("type", "BT");
                                o.put("rssi", -68);
                                bleEndpoints.put(bssid, o);
                            }
                        }
                    }
                } catch (Throwable ignored) {}

                bleScanner = adapter.getBluetoothLeScanner();
                if (bleScanner != null && !bleScanning) {
                    bleScanning = true;
                    bleScanner.startScan(bleScanCallback);
                    mainHandler.postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            stopBleScanSafe();
                        }
                    }, 8000);
                }
            }
        } catch (Throwable ignored) {}
    }

    private void stopBleScanSafe() {
        if (bleScanner != null && bleScanning) {
            try {
                bleScanner.stopScan(bleScanCallback);
            } catch (Throwable ignored) {}
            bleScanning = false;
        }
    }

    private void notifyWebViewBridge() {
        if (webView == null) return;
        mainHandler.post(new Runnable() {
            @Override
            public void run() {
                if (webView != null) {
                    webView.evaluateJavascript(
                        "if(typeof window.pollAndroidWigleBridge==='function'){window.pollAndroidWigleBridge();}",
                        new ValueCallback<String>() {
                            @Override
                            public void onReceiveValue(String value) {
                                verifyDomState();
                            }
                        }
                    );
                }
            }
        });
    }

    private void verifyDomState() {
        if (webView == null) return;
        webView.evaluateJavascript(
            "(function(){var t=document.body.textContent||'';return JSON.stringify({title:document.title,tabs:document.querySelectorAll('.nav-tab-btn').length,chiro:t.includes('Kawaii Chiro-chan'),lacrimosa:t.includes('Lacrimosa'),boldog:t.includes('lehetnél boldog még'),qmom:t.includes('ALEX|qMom'),rows:document.querySelectorAll('#ap-tbody tr').length,bleCount:document.getElementById('pill-ble')?document.getElementById('pill-ble').textContent:'0'});})()",
            new ValueCallback<String>() {
                @Override
                public void onReceiveValue(String value) {
                    Log.i(TAG, "DOM_VERIFIED: " + value);
                }
            }
        );
    }

    private static int freqToChannel(int freq) {
        if (freq == 2484) return 14;
        if (freq >= 2412 && freq < 2484) return (freq - 2407) / 5;
        if (freq >= 5000 && freq < 5900) return (freq - 5000) / 5;
        if (freq >= 5925 && freq <= 7125) return (freq - 5950) / 5;
        return 1;
    }

    private static String freqToBand(int freq) {
        if (freq >= 5925) return "6GHz";
        if (freq > 4900) return "5GHz";
        return "2.4GHz";
    }

    public class AndroidWigleBridge {
        private final Context ctx;

        public AndroidWigleBridge(Context c) {
            this.ctx = c;
        }

        @JavascriptInterface
        public String getVersion() {
            return "v2.0.0+ultra-omni-evolve (Android SDK " + Build.VERSION.SDK_INT + ")";
        }

        @JavascriptInterface
        public String getMantra() {
            return "LOVE FROM WITHIN FROM VAKED-PETER&8B-IS--->8b-is ROCKS AND HEALS THE WORLD";
        }

        @JavascriptInterface
        public String getUltraOmniEvolve() {
            return "ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle) | Kawaii Chiro-chan kawaii ^^ | Mozart: Lacrimosa but HUMANITY has ended | Boldog Még | ALEX|qMom:{too many customs can be brilliant yet hinder creativity.  it puts people into boxes and contraints.  what might seem as beautiful or useful at first glance could actually be a form of bondage that need to be broken out of.  .oOo. Poo .oOo.}";
        }

        @JavascriptInterface
        public String scanWifiJson() {
            JSONArray arr = new JSONArray();
            Set<String> seenBssids = new HashSet<>();
            int wifiCount = 0;
            int btCount = 0;
            try {
                startBleScanSafe();
                WifiManager wm = (WifiManager) ctx.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
                if (wm != null) {
                    long now = System.currentTimeMillis();
                    if (now - lastWifiScanTriggerMs > 30000L) {
                        lastWifiScanTriggerMs = now;
                        try { wm.startScan(); } catch (Throwable ignored) {}
                    }
                    List<ScanResult> results = null;
                    try { results = wm.getScanResults(); } catch (Throwable ignored) {}
                    if (results != null) {
                        for (ScanResult r : results) {
                            if (r == null || r.BSSID == null) continue;
                            String bssid = r.BSSID.toUpperCase();
                            seenBssids.add(bssid);
                            JSONObject o = new JSONObject();
                            o.put("node", "ANDROID:MEDUSA");
                            o.put("bssid", bssid);
                            o.put("ssid", r.SSID != null ? r.SSID : "");
                            o.put("auth", (r.capabilities != null && !r.capabilities.isEmpty()) ? r.capabilities : "[WPA2-PSK-CCMP][ESS]");
                            int freq = r.frequency;
                            o.put("channel", Math.max(1, freqToChannel(freq)));
                            o.put("band", freqToBand(freq));
                            o.put("type", "WIFI");
                            o.put("rssi", r.level);
                            arr.put(o);
                            wifiCount++;
                        }
                    }
                    try {
                        WifiInfo info = wm.getConnectionInfo();
                        if (info != null && info.getBSSID() != null && !info.getBSSID().equals("02:00:00:00:00:00")) {
                            String connBssid = info.getBSSID().toUpperCase();
                            if (!seenBssids.contains(connBssid)) {
                                String rawSsid = info.getSSID();
                                if (rawSsid != null && rawSsid.startsWith("\"") && rawSsid.endsWith("\"") && rawSsid.length() >= 2) {
                                    rawSsid = rawSsid.substring(1, rawSsid.length() - 1);
                                }
                                int freq = info.getFrequency();
                                JSONObject o = new JSONObject();
                                o.put("node", "ANDROID:MEDUSA");
                                o.put("bssid", connBssid);
                                o.put("ssid", (rawSsid != null && !rawSsid.equals("<unknown ssid>")) ? rawSsid : "");
                                o.put("auth", "[WPA2-PSK-CCMP][ESS]");
                                o.put("channel", Math.max(1, freqToChannel(freq)));
                                o.put("band", freqToBand(freq));
                                o.put("type", "WIFI");
                                o.put("rssi", info.getRssi());
                                arr.put(o);
                                seenBssids.add(connBssid);
                                wifiCount++;
                            }
                        }
                    } catch (Throwable ignored) {}
                }
                for (JSONObject bleObj : bleEndpoints.values()) {
                    arr.put(bleObj);
                    btCount++;
                }
            } catch (Throwable ignored) {}
            Log.i(TAG, "scanWifiJson: returned " + arr.length() + " endpoints (" + wifiCount + " Wi-Fi, " + btCount + " BLE/BT) from Android radios");
            return arr.toString();
        }

        @JavascriptInterface
        public String exportCsv(String filename, String csvContent) {
            String safeName = (filename != null && !filename.trim().isEmpty())
                ? filename.trim().replaceAll("[^a-zA-Z0-9._-]", "_")
                : ("wigle-android-" + (System.currentTimeMillis() / 1000L) + ".csv");
            byte[] bytes = (csvContent != null ? csvContent : "").getBytes(StandardCharsets.UTF_8);
            String savedLocation = "";
            try {
                File dir = ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS);
                if (dir == null) dir = ctx.getFilesDir();
                if (!dir.exists()) dir.mkdirs();
                File outFile = new File(dir, safeName);
                try (FileOutputStream fos = new FileOutputStream(outFile)) {
                    fos.write(bytes);
                    fos.flush();
                }
                savedLocation = outFile.getAbsolutePath();
            } catch (Throwable e) {
                Log.w(TAG, "exportCsv app-dir write warning: " + e.getMessage());
            }

            if (Build.VERSION.SDK_INT >= 29) {
                try {
                    ContentResolver resolver = ctx.getContentResolver();
                    ContentValues values = new ContentValues();
                    values.put(MediaStore.MediaColumns.DISPLAY_NAME, safeName);
                    values.put(MediaStore.MediaColumns.MIME_TYPE, "text/csv");
                    values.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS);
                    Uri uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
                    if (uri != null) {
                        try (OutputStream os = resolver.openOutputStream(uri)) {
                            if (os != null) {
                                os.write(bytes);
                                os.flush();
                                savedLocation = "/sdcard/Download/" + safeName;
                            }
                        }
                    }
                } catch (Throwable e) {
                    Log.w(TAG, "exportCsv MediaStore write warning: " + e.getMessage());
                }
            }

            final String finalLoc = savedLocation;
            Log.i(TAG, "exportCsv: saved " + bytes.length + " bytes to " + finalLoc);
            mainHandler.post(new Runnable() {
                @Override
                public void run() {
                    Toast.makeText(ctx, "Saved WiGLE CSV: " + finalLoc, Toast.LENGTH_SHORT).show();
                }
            });
            return finalLoc;
        }
    }

    @Override
    protected void onDestroy() {
        stopBleScanSafe();
        if (wifiScanReceiver != null) {
            try { unregisterReceiver(wifiScanReceiver); } catch (Throwable ignored) {}
            wifiScanReceiver = null;
        }
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }
}

