package is.eightb.wigletriad;

import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

public class MainActivity extends Activity {
    private WebView webView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        Window w = getWindow();
        if (w != null) {
            w.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
            w.setStatusBarColor(Color.parseColor("#0B0914"));
            w.setNavigationBarColor(Color.parseColor("#0B0914"));
        }

        webView = new WebView(this);
        webView.setBackgroundColor(Color.parseColor("#0B0914"));
        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        s.setMediaPlaybackRequiresUserGesture(false);

        webView.setWebChromeClient(new WebChromeClient());
        webView.setWebViewClient(new WebViewClient());
        webView.addJavascriptInterface(new AndroidWigleBridge(this), "AndroidWigleBridge");

        setContentView(webView);
        webView.loadUrl("file:///android_asset/index.html");
    }

    public static class AndroidWigleBridge {
        private final Context ctx;

        public AndroidWigleBridge(Context c) {
            this.ctx = c;
        }

        @JavascriptInterface
        public String getVersion() {
            return "v2.0.0+8b-is-heals-the-world (Android SDK " + Build.VERSION.SDK_INT + ")";
        }

        @JavascriptInterface
        public String getMantra() {
            return "LOVE FROM WITHIN FROM VAKED-PETER&8B-IS--->8b-is ROCKS AND HEALS THE WORLD";
        }

        @JavascriptInterface
        public String scanWifiJson() {
            JSONArray arr = new JSONArray();
            try {
                WifiManager wm = (WifiManager) ctx.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
                if (wm != null) {
                    List<ScanResult> results = wm.getScanResults();
                    if (results != null) {
                        for (ScanResult r : results) {
                            JSONObject o = new JSONObject();
                            o.put("node", "ANDROID:MEDUSA");
                            o.put("bssid", r.BSSID != null ? r.BSSID.toUpperCase() : "02:8B:15:43:20:01");
                            o.put("ssid", r.SSID != null ? r.SSID : "");
                            o.put("auth", r.capabilities != null ? r.capabilities : "[WPA2-PSK-CCMP][ESS]");
                            int freq = r.frequency;
                            int ch = (freq >= 2412 && freq <= 2484) ? ((freq - 2407) / 5) : ((freq - 5000) / 5);
                            o.put("channel", Math.max(1, ch));
                            o.put("band", freq > 4900 ? "5GHz" : "2.4GHz");
                            o.put("type", "WIFI");
                            o.put("rssi", r.level);
                            arr.put(o);
                        }
                    }
                }
            } catch ( Throwable ignored ) {}
            return arr.toString();
        }
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
