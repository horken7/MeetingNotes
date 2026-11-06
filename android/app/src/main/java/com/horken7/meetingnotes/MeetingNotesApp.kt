package com.horken7.meetingnotes

import android.app.Application

class MeetingNotesApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Store.init(this)
        Models.init(this)
        MeetingService.createChannels(this)
    }
}
