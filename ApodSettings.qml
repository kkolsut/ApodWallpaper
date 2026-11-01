import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "apodWallpaper"

    StyledText {
        width: parent.width
        text: "APOD Wallpaper"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Sets NASA's Astronomy Picture of the Day as your wallpaper. Wallpaper management must be enabled in Settings → Wallpaper."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    ToggleSetting {
        settingKey: "autoUpdate"
        label: "Update automatically"
        description: "Check for a new picture on login and on the interval below"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "checkHours"
        label: "Check interval"
        description: "A new APOD is published once a day; it's only downloaded when it changes"
        defaultValue: 3
        minimum: 1
        maximum: 12
        unit: "h"
    }

    StringSetting {
        settingKey: "apiKey"
        label: "NASA API key"
        description: "Free key from api.nasa.gov. DEMO_KEY works but is heavily rate-limited."
        placeholder: "DEMO_KEY"
        defaultValue: "DEMO_KEY"
    }

    StringSetting {
        settingKey: "saveDir"
        label: "Download folder"
        description: "Images are saved as apod-YYYY-MM-DD-<id>.jpg"
        placeholder: "~/Pictures/APOD"
        defaultValue: "~/Pictures/APOD"
    }

    ToggleSetting {
        settingKey: "preferHd"
        label: "Use HD image"
        description: "Download the full-resolution version when available"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "useVideoThumbs"
        label: "Use a still on video days"
        description: "Use a still image of the video when NASA publishes one. Off keeps the current wallpaper on video days."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "notify"
        label: "Notify on change"
        description: "Show a toast with the picture's title"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showTitle"
        label: "Show title in bar"
        description: "Only affects the optional bar widget"
        defaultValue: false
    }
}
