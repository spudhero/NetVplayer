import Foundation
import Testing
@testable import DriveEngine

struct DriveAudioMediaTests {
    @Test(arguments: ["MP3", "flac", "m4a", "wav", "ape", "ogg", "opus", "dsf"])
    func audioFilesArePlayableAcrossDriveProviders(extension fileExtension: String) {
        let name = "01 试音.\(fileExtension)"
        let quark = QuarkShareFile(
            fid: "audio", name: name, pdirFID: "0", category: 2, fileType: 1,
            size: 5_000_000, formatType: "application/octet-stream",
            isDirectory: false, isFile: true, shareFIDToken: "token"
        )
        let uc = UCShareFile(
            fid: "audio", name: name, pdirFID: "0", category: 2, fileType: 1,
            size: 5_000_000, formatType: "application/octet-stream",
            isDirectory: false, isFile: true, shareFIDToken: "token"
        )
        let baidu = BaiduShareFile(
            fileID: "audio", name: name, path: "/\(name)", size: 5_000_000,
            category: 2, isDirectory: false
        )
        let ali = AliShareFile(
            fileID: "audio", name: name, parentFileID: "0", driveID: "drive",
            type: "file", category: "audio", size: 5_000_000,
            contentType: "application/octet-stream", downloadURL: "", playURL: "",
            isDirectory: false
        )
        let p115 = P115ShareFile(
            fileID: "audio", name: name, parentID: "0", pickCode: "pick",
            size: 5_000_000, category: "audio", downloadURL: "", isDirectory: false
        )
        let pikpak = PikPakShareFile(
            fileID: "audio", name: name, parentID: "0", kind: "drive#file",
            size: 5_000_000, streamVariants: [], downloadURL: "", isDirectory: false
        )

        #expect(quark.isPlayableMedia)
        #expect(uc.isPlayableMedia)
        #expect(baidu.isPlayableMedia)
        #expect(ali.isPlayableMedia)
        #expect(p115.isPlayableMedia)
        #expect(pikpak.isPlayableMedia)
        #expect(!quark.isPlayableVideo)
        #expect(!uc.isPlayableVideo)
        #expect(!baidu.isPlayableVideo)
    }

    @Test(arguments: ["cover.jpg", "lyrics.lrc", "album.cue", "album.zip", "subtitles.sup", "notes.txt"])
    func sidecarsRemainExcludedWhenTheProviderLabelsThemAsMedia(name: String) {
        #expect(!DriveMediaClassifier.isPlayableMedia(
            name: name, formatType: "audio/mpeg", isDirectory: false, isFile: true
        ))
        #expect(!DriveMediaClassifier.isPlayableMedia(
            name: name, formatType: "video/mp4", isDirectory: false, isFile: true
        ))
    }

    @Test func audioMIMEAcceptsExtensionlessFilesButNeverDirectories() {
        #expect(DriveMediaClassifier.isPlayableMedia(
            name: "Track 01", formatType: " Audio/FLAC ", isDirectory: false, isFile: true
        ))
        #expect(!DriveMediaClassifier.isPlayableMedia(
            name: "Album.mp3", formatType: "audio/mpeg", isDirectory: true, isFile: false
        ))
        #expect(!DriveMediaClassifier.isPlayableMedia(
            name: "Track.mp3", formatType: "audio/mpeg", isDirectory: false, isFile: false
        ))
        #expect(!DriveMediaClassifier.isPlayableMedia(
            name: "Unknown", formatType: "application/octet-stream", isDirectory: false, isFile: true
        ))
    }
}
