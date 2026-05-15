//
//  ToastHostView.swift
//  WePark
//
//  W7 (§3.E): Renders the current toast from ToastService.shared.
//
//  Placement: Last child of ContentView's root ZStack, so it sits above all other layers
//  including the ASP banner. Pinned to the top via VStack { ToastHostView(); Spacer() }.
//
//  Animation: slide-down from the top safe-area inset + fade on appear;
//  fade-out + slide-up on dismiss. Driven by ToastService.show()'s
//  withAnimation(.easeInOut(duration: 0.25)) wrapping currentMessage mutations.
//
//  Accessibility: UIAccessibility.post(notification: .announcement, argument: message)
//  fires on `.onAppear` so VoiceOver reads the toast text even when focus is elsewhere.
//
//  No Calendar.current use.
//

import SwiftUI

struct ToastHostView: View {

    @State private var service = ToastService.shared

    var body: some View {
        if let message = service.currentMessage {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.82), in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
                .onAppear {
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: message
                    )
                }
        }
    }
}
