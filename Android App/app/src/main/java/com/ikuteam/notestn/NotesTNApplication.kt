package com.ikuteam.notestn

import android.app.Application
import com.ikuteam.notestn.data.DatabaseManager
import com.ikuteam.notestn.data.joplin.JoplinAccountStore

class NotesTNApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DatabaseManager.init(this)
        JoplinAccountStore.init(this)
    }
}
