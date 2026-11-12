import SwiftUI

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
                        Text("Pulsa cada tecla una vez por letra. El teclado adivina la palabra y la muestra en la barra de arriba.")
                        Text("Espacio acepta la palabra resaltada. La tecla con las flechas circulares cambia a otra candidata, y también puedes tocar una en la barra.")
                        Text("Mantén pulsada una tecla para elegir una letra exacta: tildes, ü y ñ. Así también deletreas nombres nuevos, que el teclado aprende.")
                        Text("Dos toques rápidos al espacio ponen punto y espacio, y la siguiente letra sale en mayúscula. También se pone mayúscula al empezar una frase.")
                        Text("El botón ES/EN cambia el idioma. Mantenerlo 1,5 segundos borra las palabras aprendidas.")
                        Text("Mantén pulsado el punto para ver , ? ! ¿ ¡ y '.")
                    }
                    .font(.subheadline)

                    Divider()

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
