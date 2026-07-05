package com.ikuteam.notestn

import android.app.Application
import com.ikuteam.notestn.data.DatabaseManager

class NotesTNApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DatabaseManager.init(this)
    }
}
