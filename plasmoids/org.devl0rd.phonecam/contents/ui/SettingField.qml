import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import "lib/Highlight.js" as Highlight

ColumnLayout {
    id: field

    property var spec
    property string query

    Layout.fillWidth: true
    spacing: Kirigami.Units.smallSpacing

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing

        ColumnLayout {
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            spacing: 0
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: Highlight.mark(field.spec.label, field.query, Kirigami.Theme.highlightColor)
                textFormat: Text.StyledText
                elide: Text.ElideRight
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: !!field.spec.hint
                text: field.spec.hint || ""
                font: Kirigami.Theme.smallFont
                opacity: 0.6
                wrapMode: Text.WordWrap
            }
        }
        PlasmaComponents.Label {
            visible: field.spec.kind === "slider"
            text: slider.value.toFixed(1) + "×"
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }
        QQC2.Switch {
            visible: field.spec.kind === "toggle"
            Component.onCompleted: if (field.spec.kind === "toggle") checked = field.spec.get()
            onToggled: field.spec.set(checked)
        }
        QQC2.SpinBox {
            visible: field.spec.kind === "number"
            from: field.spec.from || 0
            to: field.spec.to || 0
            editable: true
            textFromValue: (value, locale) => String(value)
            Component.onCompleted: if (field.spec.kind === "number") value = field.spec.get()
            onValueModified: field.spec.set(value)
        }
    }

    QQC2.ComboBox {
        visible: field.spec.kind === "choice"
        Layout.fillWidth: true
        textRole: "label"
        model: field.spec.kind === "choice" ? field.spec.options : []
        onActivated: function(i) { field.spec.set(field.spec.options[i].value) }
        Component.onCompleted: if (field.spec.kind === "choice") currentIndex = root.optIndex(field.spec.options, field.spec.get())
    }

    QQC2.TextField {
        visible: field.spec.kind === "text" || field.spec.kind === "password"
        Layout.fillWidth: true
        echoMode: field.spec.kind === "password" ? TextInput.Password : TextInput.Normal
        placeholderText: field.spec.placeholder || ""
        Component.onCompleted: if (field.spec.kind === "text" || field.spec.kind === "password") text = field.spec.get()
        onEditingFinished: field.spec.set(text)
    }

    QQC2.Slider {
        id: slider
        visible: field.spec.kind === "slider"
        Layout.fillWidth: true
        from: field.spec.from || 0
        to: field.spec.to || 1
        stepSize: 0.1
        Component.onCompleted: if (field.spec.kind === "slider") value = field.spec.get()
        onPressedChanged: if (!pressed) field.spec.set(value)
    }
}
