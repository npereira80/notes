package com.ikuteam.notestn.data.joplin

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Phase 1 of Joplin Cloud sync: login/logout only. Item sync is a later phase.
 */
class JoplinAccountViewModel(application: Application) : AndroidViewModel(application) {

    private val store = JoplinAccountStore.shared

    val account: StateFlow<JoplinAccount?> = store.account

    private val _isLoggingIn = MutableStateFlow(false)
    val isLoggingIn: StateFlow<Boolean> = _isLoggingIn.asStateFlow()

    private val _loginError = MutableStateFlow<String?>(null)
    val loginError: StateFlow<String?> = _loginError.asStateFlow()

    fun login(email: String, password: String, onSuccess: () -> Unit) {
        _loginError.value = null
        _isLoggingIn.value = true
        viewModelScope.launch {
            val result = JoplinCloudApi.login(email, password)
            _isLoggingIn.value = false
            result.onSuccess { session ->
                store.save(JoplinAccount(email = email, sessionId = session.id, userId = session.userId))
                onSuccess()
            }.onFailure { error ->
                _loginError.value = when (error) {
                    is JoplinCloudApi.LoginError.InvalidCredentials -> "Incorrect email or password."
                    is JoplinCloudApi.LoginError.Other -> error.message
                    is JoplinCloudApi.LoginError.Network -> "Couldn't reach Joplin Cloud. Check your connection."
                    else -> "Login failed."
                }
            }
        }
    }

    fun logout() {
        store.clear()
    }

    fun clearError() {
        _loginError.value = null
    }
}
