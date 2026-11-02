import SwiftUI

/// The Beholder mark in density-ramp characters, like the design system's other character art: an original floating
/// eye creature with ten eyestalks, mirrored left to right. Baked from Aegis's own drawing; no external artwork.
struct BeholderEmblem: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let lines = side < 90 ? Self.small : Self.large
            HUDAsciiText(
                lines: lines,
                cols: lines.count * 2,
                size: side / CGFloat(lines.count),
                tone: HUD.primary,
                aspect: HUDAscii.artAspect
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement()
        .accessibilityLabel("Beholder: a floating eye creature with ten eyestalks")
        .accessibilityAddTraits(.isImage)
    }

    /// 24 rows of 48 characters, for the empty state and larger.
    static let large = [
        "",
        "",
        "                  .*%#=  =#%*.",
        "                  .*%#=  =#%*.",
        "         .    .==:  *=    =*  :==.    .",
        "       =#%*.  #*#%  +*    *+  %#*#  .*%#=",
        "       -#@#.  .=@-  :%    %:  -@=.  .#@#-",
        "         :#=.   :#=.:%*++*%:.=#:   .=#:",
        "      .+*= :+*=:-*@@@@@@@@@@@@*-:=*+: =*+.",
        "      +*@@*+-.+@@@@@@@@@@@@@@@@@@+.-+*@@*+",
        "  --::.--. .=@@@@@@@@#*++*#@@@@@@@@=. .--.::--",
        " **%%+=+++++%@@@@@*-.=#++#=.-*@@@@@%+++++=+%%**",
        " .++=      +@@@@*.  *@@::@@*  .*@@@@+      =++.",
        "           %@@@@*:  +@@::@@+  :*@@@@%",
        "           #@@@@@@#-.=#++#=.-#@@@@@@#",
        "           +@@@@@@@@@%****%@@@@@@@@@+",
        "            #@@@%#%@@@@@@@@@@%#%@@@#",
        "            .*@@@#- .:----:. -#@@@*.",
        "              -#@@@%+-.  .-+%@@@#-",
        "                :+#@@@@@@@@@@#+:",
        "                    :--==--:",
        "",
        "",
        "",
    ]

    /// 16 rows of 32 characters, for the header and smaller.
    static let small = [
        "",
        "            :+=  =+:",
        "            :#+  +#:",
        "    .++: =#* =-  -= *#= :++.",
        "     =#: .=* .*  *. *=. :#=",
        "    :=:==-:+%#@@@@#%+:-==:=:",
        "    =#*==*@@@@@@@@@@@@*==*#=",
        ".*#+-==-#@@@#=+==+=#@@@#-==-+#*.",
        " --.   =@@%: =@==@= :%@@=   .--",
        "       +@@@#=:*++*:=#@@@+",
        "       -@@@@@@%##%@@@@@@-",
        "        =@@#===++===#@@=",
        "         .*@@#=--=#@@*.",
        "            :=++++=:",
        "",
        "",
    ]
}
