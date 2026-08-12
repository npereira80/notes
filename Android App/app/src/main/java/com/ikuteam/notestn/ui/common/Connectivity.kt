package com.ikuteam.notestn.ui.common

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext

/**
 * Whether this device currently has a working internet connection, kept up to date
 * while the calling composable is on screen.
 *
 * VALIDATED as well as INTERNET: a network that hasn't passed Android's own
 * connectivity check (a captive portal in a hotel, a Wi-Fi network whose uplink is
 * down) would otherwise read as online and leave the user staring at a sync error
 * with no explanation.
 *
 * Starts as true and corrects itself on the first callback, so a brief "no internet"
 * flash never shows on a normal launch.
 */
@Composable
internal fun rememberIsOnline(): Boolean {
    val context = LocalContext.current
    var online by remember { mutableStateOf(true) }

    DisposableEffect(context) {
        val manager = context.getSystemService(ConnectivityManager::class.java)

        fun currentlyOnline(): Boolean {
            val capabilities = manager?.getNetworkCapabilities(manager.activeNetwork) ?: return false
            return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }

        online = currentlyOnline()

        // Every callback re-reads the active network rather than trusting the event:
        // onLost fires for one network while another may already have taken over, and
        // onAvailable fires before validation finishes.
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { online = currentlyOnline() }
            override fun onLost(network: Network) { online = currentlyOnline() }
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                online = currentlyOnline()
            }
        }

        manager?.registerDefaultNetworkCallback(callback)
        onDispose { manager?.unregisterNetworkCallback(callback) }
    }

    return online
}
