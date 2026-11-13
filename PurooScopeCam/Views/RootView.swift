import SwiftUI

struct RootView: View {
    @AppStorage("puroo.privacy.noticeVersion") private var noticeVersion = 0

    var body: some View {
        Group {
            if noticeVersion == PurooPrivacyNotice.version {
                CameraScreen()
            } else {
                PurooPrivacyNotice { noticeVersion = PurooPrivacyNotice.version }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct PurooPrivacyNotice: View {
    static let version = 1
    var onContinue: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private let policy = """
    运营主体：杭州普徕光学有限公司
    更新日期：2026年10月29日

    相机与拍摄内容
    相机用于取景、拍照和录像；拒绝后不能拍摄。画面在设备上处理，拍摄文件保存到本机相册或应用目录。本应用不要求注册账号，也没有广告或行为统计服务。

    麦克风与相册
    麦克风仅在录制有声视频时使用，拒绝后仍可拍照或录制静音视频。iOS 照片权限用于保存、浏览和主动分享；Android 9 及以下需要存储权限保存拍摄内容。你可随时在系统设置中调整授权。

    运动信息与设置
    设备运动传感器用于防抖辅助与方向调整，信息在本机处理。拍摄选项与本说明的阅读状态保存在应用本地。

    可选诊断与分享
    诊断由你主动开启，不会自动上传。Android 诊断记录设备型号、系统版本、相机事件和拍摄参数，不保存图像或音频。iOS 诊断可能包含运动数据、设备计时信息及最多12对低分辨率灰度画面，仍可能反映拍摄内容。导出前请确认内容适合分享；接收方由你在系统分享界面选择。

    保存、删除与系统服务
    可在系统相册删除照片和视频。卸载应用不一定删除相册内容。系统备份、相册云同步或你选用的分享服务按相应服务设置处理文件。本应用使用 Apple 系统框架或 AndroidX/CameraX 等基础组件。

    隐私联系
    客服与隐私联系邮箱：support@puroo.cn。你可以通过此邮箱咨询权限、提出个人信息查询、更正或删除请求。我们会在必要的身份核实后处理请求。请只提供排查问题所需的信息，勿主动提供无关敏感内容。主动提交的邮件和附件仅用于沟通与排查，在完成处理且无继续保留必要时删除。

    未成年人
    未成年人应在监护人指导下阅读本说明、管理权限和选择分享内容。监护人可以通过上述邮箱提出相关请求。
    """

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let policyURL = URL(string: "https://www.puroo.cn/privacy.html") {
                        Link("查看官网隐私政策", destination: policyURL)
                            .accessibilityHint("在浏览器中打开")
                    }

                    Text(policy)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("隐私与权限说明")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(onContinue == nil ? "关闭" : "了解并继续") {
                    if let onContinue { onContinue() } else { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow).foregroundStyle(.black)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(CameraController())
        .environmentObject(MotionStabilityMonitor())
}
