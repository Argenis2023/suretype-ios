import SwiftUI
import UIKit

@main
struct SureTypeHostApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var text = ""

    private var spellInfo: String {
        let langs = UITextChecker.availableLanguages.filter { $0.lowercased().hasPrefix("es") || $0.lowercased().hasPrefix("en") }
        return langs.isEmpty ? "ninguno" : langs.sorted().joined(separator: ", ")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Para activar el teclado")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Abre Ajustes > General > Teclado > Teclados.")
                        Text("2. Toca \"Añadir teclado nuevo...\" y elige SureType.")
                        Text("3. No necesitas activar \"Permitir acceso total\".")
                        Text("4. En cualquier campo de texto, mantén pulsado el globo o el icono de emoji y elige SureType.")
                    }
                    .font(.subheadline)

                    Divider()

                    Text("Cómo se usa")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cada tecla tiene dos letras. Toca la mitad izquierda para la primera y la mitad derecha para la segunda. Tú escribes cada palabra completa.")
                        Text("Si una palabra está mal escrita, aparece en rojo en la barra de arriba con hasta tres correcciones. Toca una para reemplazarla.")
                        Text("Si la palabra en rojo sí es correcta (un nombre, por ejemplo), tócala a ella para guardarla y que no se marque más.")
                        Text("Dos toques rápidos al espacio ponen punto y espacio, y la siguiente letra sale en mayúscula. También se pone mayúscula al empezar una frase.")
                        Text("Mantén pulsada la mitad de una tecla con vocal, n o c para elegir tilde, ü, ñ o ç. Mantén pulsado el punto para ver ? ! ¿ ¡ y '.")
                        Text("El botón ES/EN cambia el idioma del corrector. Mantenerlo 1,5 segundos borra las palabras guardadas.")
                    }
                    .font(.subheadline)

                    Divider()

                    Text("Corrector disponible: " + spellInfo)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Text("Zona de prueba")
                        .font(.headline)

                    TextEditor(text: $text)
                        .frame(height: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                }
                .padding()
            }
            .navigationTitle("SureType")
        }
        .navigationViewStyle(.stack)
    }
}
