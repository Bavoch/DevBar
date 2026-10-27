package local.devbar.runtime;

import android.content.Context;
import android.content.Intent;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.UUID;
import org.json.JSONObject;

/** Call once from the development Activity.onCreate, after super.onCreate. */
public final class DevBarRuntime {
    private static final String INSTANCE_ID = UUID.randomUUID().toString();
    public static void record(Context context, Intent intent) throws Exception {
        String sync = intent.getStringExtra("devbarSyncID");
        String target = intent.getStringExtra("devbarTarget");
        if (sync == null || target == null) return;
        // This revision is built INTO the APK; never read it from the launch request.
        JSONObject build;
        try (java.io.InputStream stream = context.getAssets().open("devbar-build.json")) {
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[4096]; int n;
            while ((n = stream.read(buffer)) != -1) bytes.write(buffer, 0, n);
            build = new JSONObject(bytes.toString("UTF-8"));
        }
        JSONObject proof = new JSONObject();
        proof.put("sourceDigest", build.getString("sourceDigest"));
        proof.put("syncID", sync); proof.put("target", target);
        proof.put("instanceID", INSTANCE_ID); proof.put("pid", android.os.Process.myPid());
        File file = new File(context.getFilesDir(), "devbar-runtime.json");
        File temp = new File(context.getFilesDir(), "devbar-runtime.tmp");
        Files.write(temp.toPath(), proof.toString().getBytes(StandardCharsets.UTF_8));
        Files.move(temp.toPath(), file.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING, java.nio.file.StandardCopyOption.ATOMIC_MOVE);
    }
}
