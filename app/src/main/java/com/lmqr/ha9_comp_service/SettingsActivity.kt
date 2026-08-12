package com.lmqr.ha9_comp_service

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Bundle
import android.provider.Settings
import android.view.MenuItem
import android.view.accessibility.AccessibilityManager
import androidx.appcompat.app.AppCompatActivity
import com.lmqr.ha9_comp_service.quick_settings.toggle
import androidx.preference.Preference
import androidx.preference.PreferenceFragmentCompat
import java.io.FileOutputStream
import androidx.activity.result.contract.ActivityResultContracts
import android.widget.Toast
import android.net.Uri


class SettingsActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.settings_activity)
        if (savedInstanceState == null) {
            supportFragmentManager
                .beginTransaction()
                .replace(R.id.settings, SettingsFragment())
                .commit()
        }
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        checkPermissions()
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        return when (item.itemId) {
            android.R.id.home -> {
                finish()
                true
            }

            else -> super.onOptionsItemSelected(item)
        }
    }

    class SettingsFragment : PreferenceFragmentCompat() {

        // Picks an image and copies it to getBackgroundFileImage(), which
        // AlwaysOnDisplay.loadBackgroundImage() reads and draws as the AOD
        // background. Only meaningful in overlay-AOD mode (mode 2); the static
        // ColorFade AOD renders a shader, not a bitmap.
        private val imagePickerLauncher =
            registerForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
                uri?.let {
                    activity?.run {
                        val file = getBackgroundFileImage(this)
                        contentResolver.openInputStream(it)?.run {
                            FileOutputStream(file).use { out -> copyTo(out) }
                            close()
                            onUpdatedImage()
                            Toast.makeText(
                                requireContext(),
                                "Background image updated successfully.",
                                Toast.LENGTH_SHORT
                            ).show()
                        }
                    }
                }
            }

        // Flipping this preference is what tells A9AccessibilityService to call
        // alwaysOnDisplay.update(), which re-reads the file. loadBackgroundImage()
        // early-returns unless file.lastModified() changed, so the toggle is the
        // signal, not a redundant repaint.
        private fun onUpdatedImage() {
            preferenceManager.sharedPreferences?.toggle("aod_image_updated")
        }

        // Show only the settings belonging to the selected AOD mode. Both sets
        // exist in the XML; the unused one is hidden rather than merely disabled,
        // because a greyed-out block of ten irrelevant options is just noise.
        // Both modes' options live in the one "Always On Display" section; the
        // set that does not apply is hidden rather than greyed out. "stock"
        // hides both, since nothing here applies when the framework is left
        // to its own behaviour.
        private val staticAodKeys = listOf(
            "static_lockscreen_type",
            "static_lockscreen_opacity",
            "static_lockscreen_bg_opacity",
            "static_lockscreen_mix_color",
            "disable_show_per_app_aod_settings",
        )

        private val overlayAodKeys = listOf(
            "overlay_chess",
            "music_view_timeout",
            "select_aod_bg",
            "remove_aod_bg",
            "grant_notif_perms",
            "request_all_file",
        )

        private fun updateAodSections(mode: String? = null) {
            val m = mode
                ?: preferenceManager.sharedPreferences?.getString("aod_mode", "overlay")
                ?: "overlay"
            staticAodKeys.forEach { findPreference<Preference>(it)?.isVisible = m == "static" }
            overlayAodKeys.forEach { findPreference<Preference>(it)?.isVisible = m == "overlay" }
        }

        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            setPreferencesFromResource(R.xml.root_preferences, rootKey)

            updateAodSections()
            (findPreference("aod_mode") as Preference?)?.setOnPreferenceChangeListener { _, newValue ->
                // Applied against the NEW value: the listener runs BEFORE the
                // preference is persisted, so reading it back here would give the
                // previous mode and the sections would lag one selection behind.
                updateAodSections(newValue as? String)
                true
            }

            (findPreference("select_aod_bg") as Preference?)?.onPreferenceClickListener =
                Preference.OnPreferenceClickListener {
                    imagePickerLauncher.launch("image/*")
                    true
                }

            (findPreference("remove_aod_bg") as Preference?)?.onPreferenceClickListener =
                Preference.OnPreferenceClickListener {
                    val file = getBackgroundFileImage(requireContext())
                    if (file.exists() && file.delete()) {
                        Toast.makeText(
                            requireContext(),
                            "Background image removed successfully.",
                            Toast.LENGTH_SHORT
                        ).show()
                        onUpdatedImage()
                    } else {
                        Toast.makeText(
                            requireContext(),
                            "No background image to remove.",
                            Toast.LENGTH_SHORT
                        ).show()
                    }
                    true
                }

            // The background file lives in shared storage so other apps (KOReader
            // etc.) can write it too; that needs all-files access on API 30+.
            (findPreference("request_all_file") as Preference?)?.onPreferenceClickListener =
                Preference.OnPreferenceClickListener {
                    try {
                        startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION))
                    } catch (e: ActivityNotFoundException) {
                        startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                    }
                    true
                }

            (findPreference("grant_notif_perms") as Preference?)?.onPreferenceClickListener =
                Preference.OnPreferenceClickListener {
                    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    requireContext().startActivity(intent)
                    true
                }
        }
    }

    private fun checkPermissions(){
        if(!isAccessibilityServiceEnabled()) {
            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_HISTORY)
            try {
                startActivity(intent)
            } catch (e: ActivityNotFoundException) {
                e.printStackTrace()
            }
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val am = getSystemService(ACCESSIBILITY_SERVICE) as AccessibilityManager
        val enabledServices =
            am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
        for (enabledService in enabledServices) {
            val enabledServiceInfo: ServiceInfo = enabledService.resolveInfo.serviceInfo
            if (enabledServiceInfo.packageName.equals(packageName))
                return true
        }
        return false
    }
}