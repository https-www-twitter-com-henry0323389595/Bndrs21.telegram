import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore
import SyncCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AvatarNode
import TelegramStringFormatting
import PeerPresenceStatusManager
import ContextUI
import AccountContext
import LegacyComponents
import AudioBlob
import PeerInfoAvatarListNode

private let avatarFont = avatarPlaceholderFont(size: floor(50.0 * 16.0 / 37.0))
private let tileSize = CGSize(width: 84.0, height: 84.0)
private let backgroundCornerRadius: CGFloat = 11.0
private let videoCornerRadius: CGFloat = 23.0
private let avatarSize: CGFloat = 50.0
private let videoSize = CGSize(width: 180.0, height: 180.0)

private let accentColor: UIColor = UIColor(rgb: 0x007aff)
private let constructiveColor: UIColor = UIColor(rgb: 0x34c759)
private let destructiveColor: UIColor = UIColor(rgb: 0xff3b30)

private let borderLineWidth: CGFloat = 2.0
private let borderImage = generateImage(CGSize(width: tileSize.width, height: tileSize.height), rotatedContext: { size, context in
    let bounds = CGRect(origin: CGPoint(), size: size)
    context.clear(bounds)
    
    context.setLineWidth(borderLineWidth)
    context.setStrokeColor(constructiveColor.cgColor)
    
    context.addPath(UIBezierPath(roundedRect: bounds.insetBy(dx: (borderLineWidth - UIScreenPixel) / 2.0, dy: (borderLineWidth - UIScreenPixel) / 2.0), cornerRadius: backgroundCornerRadius - UIScreenPixel).cgPath)
    context.strokePath()
})

private let fadeColor = UIColor(rgb: 0x000000, alpha: 0.5)
private let fadeHeight: CGFloat = 50.0

private var fadeImage: UIImage? = {
    return generateImage(CGSize(width: fadeHeight, height: fadeHeight), rotatedContext: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)
        
        let colorsArray = [fadeColor.withAlphaComponent(0.0).cgColor, fadeColor.cgColor] as CFArray
        var locations: [CGFloat] = [1.0, 0.0]
        let gradient = CGGradient(colorsSpace: deviceColorSpace, colors: colorsArray, locations: &locations)!
        context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
    })
}()

final class VoiceChatFullscreenParticipantItem: ListViewItem {
    enum Icon {
        case none
        case microphone(Bool, UIColor)
        case invite(Bool)
        case wantsToSpeak
    }
    
    enum Color {
        case generic
        case accent
        case constructive
        case destructive
    }
    
    let presentationData: ItemListPresentationData
    let nameDisplayOrder: PresentationPersonNameOrder
    let context: AccountContext
    let peer: Peer
    let icon: Icon
    let text: VoiceChatParticipantItem.ParticipantText
    let color: Color
    let isLandscape: Bool
    let active: Bool
    let getAudioLevel: (() -> Signal<Float, NoError>)?
    let getVideo: () -> GroupVideoNode?
    let action: ((ASDisplayNode?) -> Void)?
    let contextAction: ((ASDisplayNode, ContextGesture?) -> Void)?
    let getUpdatingAvatar: () -> Signal<(TelegramMediaImageRepresentation, Float)?, NoError>
    
    public let selectable: Bool = true
    
    public init(presentationData: ItemListPresentationData, nameDisplayOrder: PresentationPersonNameOrder, context: AccountContext, peer: Peer, icon: Icon, text: VoiceChatParticipantItem.ParticipantText, color: Color, isLandscape: Bool, active: Bool, getAudioLevel: (() -> Signal<Float, NoError>)?, getVideo: @escaping () -> GroupVideoNode?, action: ((ASDisplayNode?) -> Void)?, contextAction: ((ASDisplayNode, ContextGesture?) -> Void)? = nil, getUpdatingAvatar: @escaping () -> Signal<(TelegramMediaImageRepresentation, Float)?, NoError>) {
        self.presentationData = presentationData
        self.nameDisplayOrder = nameDisplayOrder
        self.context = context
        self.peer = peer
        self.icon = icon
        self.text = text
        self.color = color
        self.isLandscape = isLandscape
        self.active = active
        self.getAudioLevel = getAudioLevel
        self.getVideo = getVideo
        self.action = action
        self.contextAction = contextAction
        self.getUpdatingAvatar = getUpdatingAvatar
    }
        
    public func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = VoiceChatFullscreenParticipantItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, previousItem == nil, nextItem == nil)
            
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            
            Queue.mainQueue().async {
                completion(node, {
                    return (node.avatarNode.ready, { _ in apply(synchronousLoads, false) })
                })
            }
        }
    }
    
    public func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? VoiceChatFullscreenParticipantItemNode {
                let makeLayout = nodeValue.asyncLayout()
                
                var animated = true
                if case .None = animation {
                    animated = false
                }
                
                async {
                    let (layout, apply) = makeLayout(self, params, previousItem == nil, nextItem == nil)
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply(false, animated)
                        })
                    }
                }
            }
        }
    }
    
    public func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
    }
}

class VoiceChatFullscreenParticipantItemNode: ItemListRevealOptionsItemNode {
    let contextSourceNode: ContextExtractedContentContainingNode
    private let containerNode: ContextControllerSourceNode
    let backgroundImageNode: ASImageNode
    private let extractedBackgroundImageNode: ASImageNode
    let offsetContainerNode: ASDisplayNode
    let highlightNode: ASImageNode
    
    private var extractedRect: CGRect?
    private var nonExtractedRect: CGRect?
    private var extractedVerticalOffset: CGFloat?
        
    let avatarNode: AvatarNode
    let contentWrapperNode: ASDisplayNode
    private let titleNode: TextNode
    private let statusNode: VoiceChatParticipantStatusNode
    private var credibilityIconNode: ASImageNode?
        
    private let actionContainerNode: ASDisplayNode
    private var animationNode: VoiceChatMicrophoneNode?
    private var iconNode: ASImageNode?
    private var raiseHandNode: VoiceChatRaiseHandNode?
    private var actionButtonNode: HighlightableButtonNode
    
    var audioLevelView: VoiceBlobView?
    private let audioLevelDisposable = MetaDisposable()
    private var didSetupAudioLevel = false
    
    private var absoluteLocation: (CGRect, CGSize)?
    
    private var layoutParams: (VoiceChatFullscreenParticipantItem, ListViewItemLayoutParams, Bool, Bool)?
    private var isExtracted = false
    private var animatingExtraction = false
    private var animatingSelection = false
    private var wavesColor: UIColor?
    
    let videoContainerNode: ASDisplayNode
    private let videoFadeNode: ASDisplayNode
    var videoNode: GroupVideoNode?
    
    private var profileNode: VoiceChatPeerProfileNode?
    
    private var raiseHandTimer: SwiftSignalKit.Timer?
    private var silenceTimer: SwiftSignalKit.Timer?
    
    var item: VoiceChatFullscreenParticipantItem? {
        return self.layoutParams?.0
    }
    
    init() {
        self.contextSourceNode = ContextExtractedContentContainingNode()
        self.containerNode = ContextControllerSourceNode()
        
        self.backgroundImageNode = ASImageNode()
        self.backgroundImageNode.clipsToBounds = true
        self.backgroundImageNode.displaysAsynchronously = false
        self.backgroundImageNode.alpha = 0.0
        
        self.extractedBackgroundImageNode = ASImageNode()
        self.extractedBackgroundImageNode.clipsToBounds = true
        self.extractedBackgroundImageNode.displaysAsynchronously = false
        self.extractedBackgroundImageNode.alpha = 0.0
        
        self.highlightNode = ASImageNode()
        self.highlightNode.displaysAsynchronously = false
        self.highlightNode.image = borderImage
        self.highlightNode.isHidden = true
        
        self.offsetContainerNode = ASDisplayNode()
        
        self.avatarNode = AvatarNode(font: avatarFont)
        self.avatarNode.frame = CGRect(origin: CGPoint(), size: CGSize(width: avatarSize, height: avatarSize))
        
        self.contentWrapperNode = ASDisplayNode()
        
        self.videoContainerNode = ASDisplayNode()
        self.videoContainerNode.clipsToBounds = true
        
        self.videoFadeNode = ASDisplayNode()
        self.videoFadeNode.displaysAsynchronously = false
        if let image = fadeImage {
            self.videoFadeNode.backgroundColor = UIColor(patternImage: image)
        }
        self.videoContainerNode.addSubnode(self.videoFadeNode)
        
        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.contentMode = .left
        self.titleNode.contentsScale = UIScreen.main.scale
        
        self.statusNode = VoiceChatParticipantStatusNode()
    
        self.actionContainerNode = ASDisplayNode()
        self.actionButtonNode = HighlightableButtonNode()
        
        super.init(layerBacked: false, dynamicBounce: false, rotated: false, seeThrough: false)
        
        self.isAccessibilityElement = true
        
        self.containerNode.addSubnode(self.contextSourceNode)
        self.containerNode.targetNodeForActivationProgress = self.contextSourceNode.contentNode
        self.addSubnode(self.containerNode)
        
        self.contextSourceNode.contentNode.addSubnode(self.backgroundImageNode)
        self.backgroundImageNode.addSubnode(self.extractedBackgroundImageNode)
        self.contextSourceNode.contentNode.addSubnode(self.offsetContainerNode)
        self.offsetContainerNode.addSubnode(self.videoContainerNode)
        self.offsetContainerNode.addSubnode(self.contentWrapperNode)
        self.contentWrapperNode.addSubnode(self.titleNode)
        self.contentWrapperNode.addSubnode(self.actionContainerNode)
        self.actionContainerNode.addSubnode(self.actionButtonNode)
        self.offsetContainerNode.addSubnode(self.avatarNode)
        self.contextSourceNode.contentNode.addSubnode(self.highlightNode)
        self.containerNode.targetNodeForActivationProgress = self.contextSourceNode.contentNode
                
        self.containerNode.shouldBegin = { [weak self] location in
            guard let _ = self else {
                return false
            }
            return true
        }
        self.containerNode.activated = { [weak self] gesture, _ in
            guard let strongSelf = self, let item = strongSelf.layoutParams?.0, let contextAction = item.contextAction else {
                gesture.cancel()
                return
            }
            contextAction(strongSelf.contextSourceNode, gesture)
        }
        self.contextSourceNode.willUpdateIsExtractedToContextPreview = { [weak self] isExtracted, transition in
            guard let strongSelf = self, let _ = strongSelf.item else {
                return
            }
            strongSelf.updateIsExtracted(isExtracted, transition: transition)
        }
    }
    
    deinit {
        self.audioLevelDisposable.dispose()
        self.raiseHandTimer?.invalidate()
        self.silenceTimer?.invalidate()
    }
    
    override func selected() {
        super.selected()
        self.layoutParams?.0.action?(self.contextSourceNode)
    }
    
    func animateTransitionIn(from sourceNode: ASDisplayNode?, containerNode: ASDisplayNode, transition: ContainedViewLayoutTransition, animate: Bool = true) {
        guard let item = self.item else {
            return
        }
        var duration: Double = 0.2
        var timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue
        if case let .animated(transitionDuration, curve) = transition {
            duration = transitionDuration
            timingFunction = curve.timingFunction
        }
        
        let initialAnimate = animate
        if let sourceNode = sourceNode as? VoiceChatTileItemNode {
            var startContainerPosition = sourceNode.view.convert(sourceNode.bounds, to: containerNode.view).center
            var animate = initialAnimate
            if startContainerPosition.y < -tileHeight || startContainerPosition.y > containerNode.frame.height + tileHeight {
                animate = false
            }
            
            if let videoNode = sourceNode.videoNode {
                if item.active {
                    self.avatarNode.alpha = 1.0
                    videoNode.alpha = 0.0
                    startContainerPosition = startContainerPosition.offsetBy(dx: 0.0, dy: 9.0)
                } else {
                    self.avatarNode.alpha = 0.0
                }
            
                sourceNode.videoNode = nil
                self.videoNode = videoNode
                self.videoContainerNode.insertSubnode(videoNode, at: 0)
 
                if animate {
                    videoNode.updateLayout(size: videoSize, layoutMode: .fillOrFitToSquare, transition: transition)
                     
                    let scale = sourceNode.bounds.width / videoSize.width
                    self.videoContainerNode.layer.animateScale(from: sourceNode.bounds.width / videoSize.width, to: tileSize.width / videoSize.width, duration: duration, timingFunction: timingFunction)
                    self.videoContainerNode.layer.animate(from: backgroundCornerRadius * (1.0 / scale) as NSNumber, to: videoCornerRadius as NSNumber, keyPath: "cornerRadius", timingFunction: timingFunction, duration: duration, removeOnCompletion: false, completion: { _ in
                    })
                    
                    self.videoFadeNode.alpha = 1.0
                    self.videoFadeNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
                } else if initialAnimate {
                    videoNode.updateLayout(size: videoSize, layoutMode: .fillOrFitToSquare, transition: .immediate)
                    self.videoFadeNode.alpha = 1.0
                }
            }
            
            if animate {
                let initialPosition = self.contextSourceNode.position
                let targetContainerPosition = self.contextSourceNode.view.convert(self.contextSourceNode.bounds, to: containerNode.view).center

                self.contextSourceNode.position = targetContainerPosition
                containerNode.addSubnode(self.contextSourceNode)

                self.contextSourceNode.layer.animatePosition(from: startContainerPosition, to: targetContainerPosition, duration: duration, timingFunction: timingFunction, completion: { [weak self] _ in
                    if let strongSelf = self {
                        strongSelf.contextSourceNode.position = initialPosition
                        strongSelf.containerNode.addSubnode(strongSelf.contextSourceNode)
                    }
                })

                if item.active {
                    self.highlightNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                    self.highlightNode.layer.animateScale(from: 0.001, to: 1.0, duration: 0.2, timingFunction: timingFunction)
                }

                self.backgroundImageNode.layer.animateScale(from: 0.001, to: 1.0, duration: duration, timingFunction: timingFunction)
                self.backgroundImageNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration, timingFunction: timingFunction)
                self.contentWrapperNode.layer.animateScale(from: 0.001, to: 1.0, duration: duration, timingFunction: timingFunction)
                self.contentWrapperNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration, timingFunction: timingFunction)
            } else if !initialAnimate {
                if transition.isAnimated {
                    self.contextSourceNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration, timingFunction: timingFunction)
                    self.contextSourceNode.layer.animateScale(from: 0.0, to: 1.0, duration: duration, timingFunction: timingFunction)
                }
            }
        } else if let sourceNode = sourceNode as? VoiceChatParticipantItemNode, let _ = sourceNode.item {
            var startContainerPosition = sourceNode.avatarNode.view.convert(sourceNode.avatarNode.bounds, to: containerNode.view).center
            var animate = true
            if startContainerPosition.y < -tileHeight || startContainerPosition.y > containerNode.frame.height + tileHeight {
                animate = false
            }
            startContainerPosition = startContainerPosition.offsetBy(dx: 0.0, dy: 9.0)

            if animate {
                sourceNode.avatarNode.alpha = 0.0
                sourceNode.audioLevelView?.alpha = 0.0

                let initialPosition = self.contextSourceNode.position
                let targetContainerPosition = self.contextSourceNode.view.convert(self.contextSourceNode.bounds, to: containerNode.view).center

                self.contextSourceNode.position = targetContainerPosition
                containerNode.addSubnode(self.contextSourceNode)

                self.contextSourceNode.layer.animatePosition(from: startContainerPosition, to: targetContainerPosition, duration: duration, timingFunction: timingFunction, completion: { [weak self, weak sourceNode] _ in
                    if let strongSelf = self, let sourceNode = sourceNode {
                        sourceNode.avatarNode.alpha = 1.0
                        sourceNode.audioLevelView?.alpha = 1.0
                        strongSelf.contextSourceNode.position = initialPosition
                        strongSelf.containerNode.addSubnode(strongSelf.contextSourceNode)
                    }
                })

                if item.active {
                    self.highlightNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                    self.highlightNode.layer.animateScale(from: 0.001, to: 1.0, duration: 0.2, timingFunction: timingFunction)
                }
                
                self.avatarNode.layer.animateScale(from: 0.8, to: 1.0, duration: duration, timingFunction: timingFunction)

                self.backgroundImageNode.layer.animateScale(from: 0.001, to: 1.0, duration: duration, timingFunction: timingFunction)
                self.backgroundImageNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration, timingFunction: timingFunction)
                self.contentWrapperNode.layer.animateScale(from: 0.001, to: 1.0, duration: duration, timingFunction: timingFunction)
                self.contentWrapperNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration, timingFunction: timingFunction)
            }
        } else {
            if transition.isAnimated {
                self.contextSourceNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration, timingFunction: timingFunction)
                self.contextSourceNode.layer.animateScale(from: 0.0, to: 1.0, duration: duration, timingFunction: timingFunction)
            }
        }
    }
    private func updateIsExtracted(_ isExtracted: Bool, transition: ContainedViewLayoutTransition) {
        guard self.isExtracted != isExtracted,  let extractedRect = self.extractedRect, let nonExtractedRect = self.nonExtractedRect, let item = self.item else {
            return
        }
        self.isExtracted = isExtracted
        
        if isExtracted {
            let profileNode = VoiceChatPeerProfileNode(context: item.context, size: extractedRect.size, peer: item.peer, text: item.text, customNode: self.videoContainerNode, additionalEntry: .single(nil), requestDismiss: { [weak self] in
                self?.contextSourceNode.requestDismiss?()
            })
            profileNode.frame = CGRect(origin: CGPoint(), size: extractedRect.size)
            self.profileNode = profileNode
            self.contextSourceNode.contentNode.addSubnode(profileNode)

            profileNode.animateIn(from: self, targetRect: extractedRect, transition: transition)
            
            self.contextSourceNode.contentNode.customHitTest = { [weak self] point in
                if let strongSelf = self, let profileNode = strongSelf.profileNode {
                    if profileNode.avatarListWrapperNode.frame.contains(point) {
                        return profileNode.avatarListNode.view
                    }
                }
                return nil
            }
        } else if let profileNode = self.profileNode {
            self.profileNode = nil
            profileNode.animateOut(to: self, targetRect: nonExtractedRect, transition: transition)
            
            self.contextSourceNode.contentNode.customHitTest = nil
        }
    }
    
    func asyncLayout() -> (_ item: VoiceChatFullscreenParticipantItem, _ params: ListViewItemLayoutParams, _ first: Bool, _ last: Bool) -> (ListViewItemNodeLayout, (Bool, Bool) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeStatusLayout = self.statusNode.asyncLayout()
        
        let currentItem = self.layoutParams?.0
        let hasVideo = self.videoNode != nil
        
        return { item, params, first, last in
            let titleFont = Font.semibold(13.0)
            var titleAttributedString: NSAttributedString?
            
            var titleColor = item.presentationData.theme.list.itemPrimaryTextColor
            if !hasVideo || item.active {
                switch item.color {
                    case .generic:
                        titleColor = item.presentationData.theme.list.itemPrimaryTextColor
                    case .accent:
                        titleColor = item.presentationData.theme.list.itemAccentColor
                    case .constructive:
                        titleColor = constructiveColor
                    case .destructive:
                        titleColor = destructiveColor
                }
            }
            let currentBoldFont: UIFont = titleFont
            
            if let user = item.peer as? TelegramUser {
                if let firstName = user.firstName, let lastName = user.lastName, !firstName.isEmpty, !lastName.isEmpty {
                    titleAttributedString = NSAttributedString(string: firstName, font: titleFont, textColor: titleColor)
                } else if let firstName = user.firstName, !firstName.isEmpty {
                    titleAttributedString = NSAttributedString(string: firstName, font: currentBoldFont, textColor: titleColor)
                } else if let lastName = user.lastName, !lastName.isEmpty {
                    titleAttributedString = NSAttributedString(string: lastName, font: currentBoldFont, textColor: titleColor)
                } else {
                    titleAttributedString = NSAttributedString(string: item.presentationData.strings.User_DeletedAccount, font: currentBoldFont, textColor: titleColor)
                }
            } else if let group = item.peer as? TelegramGroup {
                titleAttributedString = NSAttributedString(string: group.title, font: currentBoldFont, textColor: titleColor)
            } else if let channel = item.peer as? TelegramChannel {
                titleAttributedString = NSAttributedString(string: channel.title, font: currentBoldFont, textColor: titleColor)
            }
            
            var wavesColor = UIColor(rgb: 0x34c759)
            switch item.color {
                case .accent:
                    wavesColor = accentColor
                case .destructive:
                    wavesColor = destructiveColor
                default:
                    break
            }

            let leftInset: CGFloat = 58.0 + params.leftInset
            
            var titleIconsWidth: CGFloat = 0.0
            var currentCredibilityIconImage: UIImage?
            var credibilityIconOffset: CGFloat = 0.0
            if item.peer.isScam {
                currentCredibilityIconImage = PresentationResourcesChatList.scamIcon(item.presentationData.theme, strings: item.presentationData.strings, type: .regular)
                credibilityIconOffset = 2.0
            } else if item.peer.isFake {
                currentCredibilityIconImage = PresentationResourcesChatList.fakeIcon(item.presentationData.theme, strings: item.presentationData.strings, type: .regular)
                credibilityIconOffset = 2.0
            } else if item.peer.isVerified {
                currentCredibilityIconImage = PresentationResourcesChatList.verifiedIcon(item.presentationData.theme)
                credibilityIconOffset = 3.0
            }
            
            if let currentCredibilityIconImage = currentCredibilityIconImage {
                titleIconsWidth += 4.0 + currentCredibilityIconImage.size.width
            }
                      
            let constrainedWidth = params.width - 24.0 - 10.0
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: titleAttributedString, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: constrainedWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
                        
            let availableWidth = params.availableHeight
            let (statusLayout, _) = makeStatusLayout(CGSize(width: availableWidth - 30.0, height: CGFloat.greatestFiniteMagnitude), item.text, true)
            
            let contentSize = tileSize
            let insets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: !last ? 6.0 : 0.0, right: 0.0)
                            
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
                        
            return (layout, { [weak self] synchronousLoad, animated in
                if let strongSelf = self {
                    let hadItem = strongSelf.layoutParams?.0 != nil
                    strongSelf.layoutParams = (item, params, first, last)
                    strongSelf.wavesColor = wavesColor
                    
                    let videoContainerScale = tileSize.width / videoSize.width
                    
                    let videoNode = item.getVideo()
                    if let currentVideoNode = strongSelf.videoNode, currentVideoNode !== videoNode {
                        if videoNode == nil {
                            let transition = ContainedViewLayoutTransition.animated(duration: 0.2, curve: .easeInOut)
                            if strongSelf.avatarNode.alpha.isZero {
                                strongSelf.animatingSelection = true
                                strongSelf.videoContainerNode.layer.animateScale(from: videoContainerScale, to: 0.001, duration: 0.2)
                                strongSelf.avatarNode.layer.animateScale(from: 0.0, to: 1.0, duration: 0.2, completion: { [weak self] _ in
                                    self?.animatingSelection = false
                                })
                                strongSelf.videoContainerNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: -9.0), duration: 0.2, additive: true)
                                strongSelf.audioLevelView?.layer.animateScale(from: 0.0, to: 1.0, duration: 0.2)
                            }
                            transition.updateAlpha(node: currentVideoNode, alpha: 0.0)
                            transition.updateAlpha(node: strongSelf.videoFadeNode, alpha: 0.0)
                            transition.updateAlpha(node: strongSelf.avatarNode, alpha: 1.0)
                            if let audioLevelView = strongSelf.audioLevelView {
                                transition.updateAlpha(layer: audioLevelView.layer, alpha: 1.0)
                            }
                        } else {
                            currentVideoNode.removeFromSupernode()
                        }
                    }
                    
                    let videoNodeUpdated = strongSelf.videoNode !== videoNode
                    strongSelf.videoNode = videoNode
                    
                    let nonExtractedRect: CGRect
                    let avatarFrame: CGRect
                    let titleFrame: CGRect
                    let animationSize: CGSize
                    let animationFrame: CGRect
                    let animationScale: CGFloat
                    
                    nonExtractedRect = CGRect(origin: CGPoint(), size: layout.contentSize)
                    strongSelf.containerNode.transform = CATransform3DMakeRotation(item.isLandscape ? 0.0 : CGFloat.pi / 2.0, 0.0, 0.0, 1.0)
                    avatarFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - avatarSize) / 2.0), y: 7.0), size: CGSize(width: avatarSize, height: avatarSize))
                    
                    animationSize = CGSize(width: 36.0, height: 36.0)
                    animationScale = 0.66667
                    animationFrame = CGRect(x: layout.size.width - 29.0, y: 55.0, width: 24.0, height: 24.0)
                    titleFrame = CGRect(origin: CGPoint(x: 8.0, y: 63.0), size: titleLayout.size)
                                    
                    let extractedWidth = availableWidth
                    let extractedRect = CGRect(x: 0.0, y: 0.0, width: extractedWidth, height: extractedWidth + statusLayout.height + 39.0)
                    strongSelf.extractedRect = extractedRect
                    strongSelf.nonExtractedRect = nonExtractedRect
                    
                    if strongSelf.isExtracted {
                        strongSelf.backgroundImageNode.frame = extractedRect
                    } else {
                        strongSelf.backgroundImageNode.frame = nonExtractedRect
                    }
                    if strongSelf.backgroundImageNode.image == nil {
                        strongSelf.backgroundImageNode.image = generateStretchableFilledCircleImage(diameter: backgroundCornerRadius * 2.0, color: UIColor(rgb: 0x1c1c1e))
                        strongSelf.backgroundImageNode.alpha = 1.0
                    }
                    strongSelf.extractedBackgroundImageNode.frame = strongSelf.backgroundImageNode.bounds
                    strongSelf.contextSourceNode.contentRect = extractedRect
                    
                    let contentBounds = CGRect(origin: CGPoint(), size: layout.contentSize)
                    strongSelf.containerNode.frame = contentBounds
                    strongSelf.contextSourceNode.frame = contentBounds
                    strongSelf.contentWrapperNode.frame = contentBounds
                    strongSelf.offsetContainerNode.frame = contentBounds
                    strongSelf.contextSourceNode.contentNode.frame = contentBounds
                    strongSelf.actionContainerNode.frame = contentBounds
                    strongSelf.highlightNode.frame = contentBounds
                    
                    strongSelf.containerNode.isGestureEnabled = item.contextAction != nil
                        
                    strongSelf.accessibilityLabel = titleAttributedString?.string
                    var combinedValueString = ""
//                    if let statusString = statusAttributedString?.string, !statusString.isEmpty {
//                        combinedValueString.append(statusString)
//                    }
                    
                    strongSelf.accessibilityValue = combinedValueString
                                        
                    let transition: ContainedViewLayoutTransition
                    if animated && hadItem {
                        transition = ContainedViewLayoutTransition.animated(duration: 0.3, curve: .easeInOut)
                    } else {
                        transition = .immediate
                    }
                                                            
                    let _ = titleApply()               
                    transition.updateFrame(node: strongSelf.titleNode, frame: titleFrame)
                
                    if let currentCredibilityIconImage = currentCredibilityIconImage {
                        let iconNode: ASImageNode
                        if let current = strongSelf.credibilityIconNode {
                            iconNode = current
                        } else {
                            iconNode = ASImageNode()
                            iconNode.isLayerBacked = true
                            iconNode.displaysAsynchronously = false
                            iconNode.displayWithoutProcessing = true
                            strongSelf.offsetContainerNode.addSubnode(iconNode)
                            strongSelf.credibilityIconNode = iconNode
                        }
                        iconNode.image = currentCredibilityIconImage
                        transition.updateFrame(node: iconNode, frame: CGRect(origin: CGPoint(x: leftInset + titleLayout.size.width + 3.0, y: credibilityIconOffset), size: currentCredibilityIconImage.size))
                    } else if let credibilityIconNode = strongSelf.credibilityIconNode {
                        strongSelf.credibilityIconNode = nil
                        credibilityIconNode.removeFromSupernode()
                    }
                    
                    transition.updateFrameAsPositionAndBounds(node: strongSelf.avatarNode, frame: avatarFrame)
                    
                    let blobFrame = avatarFrame.insetBy(dx: -18.0, dy: -18.0)
                    if let getAudioLevel = item.getAudioLevel {
                        if !strongSelf.didSetupAudioLevel || currentItem?.peer.id != item.peer.id {
                            strongSelf.audioLevelView?.frame = blobFrame
                            strongSelf.didSetupAudioLevel = true
                            strongSelf.audioLevelDisposable.set((getAudioLevel()
                            |> deliverOnMainQueue).start(next: { value in
                                guard let strongSelf = self else {
                                    return
                                }
                                
                                if strongSelf.audioLevelView == nil, value > 0.0 {
                                    let audioLevelView = VoiceBlobView(
                                        frame: blobFrame,
                                        maxLevel: 1.5,
                                        smallBlobRange: (0, 0),
                                        mediumBlobRange: (0.69, 0.87),
                                        bigBlobRange: (0.71, 1.0)
                                    )
                                    
                                    let maskRect = CGRect(origin: .zero, size: blobFrame.size)
                                    let playbackMaskLayer = CAShapeLayer()
                                    playbackMaskLayer.frame = maskRect
                                    playbackMaskLayer.fillRule = .evenOdd
                                    let maskPath = UIBezierPath()
                                    maskPath.append(UIBezierPath(roundedRect: maskRect.insetBy(dx: 18, dy: 18), cornerRadius: 22))
                                    maskPath.append(UIBezierPath(rect: maskRect))
                                    playbackMaskLayer.path = maskPath.cgPath
                                    audioLevelView.layer.mask = playbackMaskLayer
                                    
                                    audioLevelView.setColor(wavesColor)
                                    audioLevelView.alpha = strongSelf.isExtracted ? 0.0 : 1.0
                                    
                                    strongSelf.audioLevelView = audioLevelView
                                    strongSelf.offsetContainerNode.view.insertSubview(audioLevelView, at: 0)
                                    
                                    if let item = strongSelf.item, strongSelf.videoNode != nil && !item.active {
                                        audioLevelView.alpha = 0.0
                                    }
                                }
                                
                                let level = min(1.0, max(0.0, CGFloat(value)))
                                if let audioLevelView = strongSelf.audioLevelView {
                                    audioLevelView.updateLevel(CGFloat(value))
                                    
                                    let avatarScale: CGFloat
                                    if value > 0.02 {
                                        audioLevelView.startAnimating()
                                        avatarScale = 1.03 + level * 0.13
                                        if let wavesColor = strongSelf.wavesColor {
                                            audioLevelView.setColor(wavesColor, animated: true)
                                        }

                                        if let silenceTimer = strongSelf.silenceTimer {
                                            silenceTimer.invalidate()
                                            strongSelf.silenceTimer = nil
                                        }
                                    } else {
                                        avatarScale = 1.0
                                        if strongSelf.silenceTimer == nil {
                                            let silenceTimer = SwiftSignalKit.Timer(timeout: 1.0, repeat: false, completion: { [weak self] in
                                                self?.audioLevelView?.stopAnimating(duration: 0.75)
                                                self?.silenceTimer = nil
                                            }, queue: Queue.mainQueue())
                                            strongSelf.silenceTimer = silenceTimer
                                            silenceTimer.start()
                                        }
                                    }
                                    
                                    if !strongSelf.animatingSelection {
                                        let transition: ContainedViewLayoutTransition = .animated(duration: 0.15, curve: .easeInOut)
                                        transition.updateTransformScale(node: strongSelf.avatarNode, scale: strongSelf.isExtracted ? 1.0 : avatarScale, beginWithCurrentState: true)
                                    }
                                }
                            }))
                        }
                    } else if let audioLevelView = strongSelf.audioLevelView {
                        strongSelf.audioLevelView = nil
                        audioLevelView.removeFromSuperview()
                        
                        strongSelf.audioLevelDisposable.set(nil)
                    }
                    
                    var overrideImage: AvatarNodeImageOverride?
                    if item.peer.isDeleted {
                        overrideImage = .deletedIcon
                    }
                    strongSelf.avatarNode.setPeer(context: item.context, theme: item.presentationData.theme, peer: item.peer, overrideImage: overrideImage, emptyColor: item.presentationData.theme.list.mediaPlaceholderColor, synchronousLoad: synchronousLoad, storeUnrounded: true)
                
                    var hadMicrophoneNode = false
                    var hadRaiseHandNode = false
                    var hadIconNode = false
                    var nodeToAnimateIn: ASDisplayNode?
                    
                    if case let .microphone(muted, color) = item.icon {
                        let animationNode: VoiceChatMicrophoneNode
                        if let current = strongSelf.animationNode {
                            animationNode = current
                        } else {
                            animationNode = VoiceChatMicrophoneNode()
                            strongSelf.animationNode = animationNode
                            strongSelf.actionButtonNode.addSubnode(animationNode)
                            
                            nodeToAnimateIn = animationNode
                        }
                        var color = color
                        if color.rgb == 0x979797 {
                            color = UIColor(rgb: 0xffffff)
                        }
                        animationNode.update(state: VoiceChatMicrophoneNode.State(muted: muted, filled: true, color: color), animated: true)
                        strongSelf.actionButtonNode.isUserInteractionEnabled = false
                    } else if let animationNode = strongSelf.animationNode {
                        hadMicrophoneNode = true
                        strongSelf.animationNode = nil
                        animationNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
                        animationNode.layer.animateScale(from: 1.0, to: 0.001, duration: 0.2, removeOnCompletion: false, completion: { [weak animationNode] _ in
                            animationNode?.removeFromSupernode()
                        })
                    }
                    
                    if case .wantsToSpeak = item.icon {
                        let raiseHandNode: VoiceChatRaiseHandNode
                        if let current = strongSelf.raiseHandNode {
                            raiseHandNode = current
                        } else {
                            raiseHandNode = VoiceChatRaiseHandNode(color: item.presentationData.theme.list.itemAccentColor)
                            raiseHandNode.contentMode = .center
                            strongSelf.raiseHandNode = raiseHandNode
                            strongSelf.actionButtonNode.addSubnode(raiseHandNode)
                            
                            nodeToAnimateIn = raiseHandNode
                            raiseHandNode.playRandomAnimation()
                            
                            strongSelf.raiseHandTimer = SwiftSignalKit.Timer(timeout: Double.random(in: 8.0 ... 10.5), repeat: true, completion: {
                                self?.raiseHandNode?.playRandomAnimation()
                            }, queue: Queue.mainQueue())
                            strongSelf.raiseHandTimer?.start()
                        }
                        strongSelf.actionButtonNode.isUserInteractionEnabled = false
                    } else if let raiseHandNode = strongSelf.raiseHandNode {
                        hadRaiseHandNode = true
                        strongSelf.raiseHandNode = nil
                        if let raiseHandTimer = strongSelf.raiseHandTimer {
                            strongSelf.raiseHandTimer = nil
                            raiseHandTimer.invalidate()
                        }
                        raiseHandNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
                        raiseHandNode.layer.animateScale(from: 1.0, to: 0.001, duration: 0.2, removeOnCompletion: false, completion: { [weak raiseHandNode] _ in
                            raiseHandNode?.removeFromSupernode()
                        })
                    }
                    
                    if case let .invite(invited) = item.icon {
                        let iconNode: ASImageNode
                        if let current = strongSelf.iconNode {
                            iconNode = current
                        } else {
                            iconNode = ASImageNode()
                            iconNode.contentMode = .center
                            strongSelf.iconNode = iconNode
                            strongSelf.actionButtonNode.addSubnode(iconNode)
                            
                            nodeToAnimateIn = iconNode
                        }
                        
                        if invited {
                            iconNode.image = generateTintedImage(image: UIImage(bundleImageName: "Call/Context Menu/Invited"), color: UIColor(rgb: 0x979797))
                        } else {
                            iconNode.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/AddUser"), color: item.presentationData.theme.list.itemAccentColor)
                        }
                        strongSelf.actionButtonNode.isUserInteractionEnabled = false
                    } else if let iconNode = strongSelf.iconNode {
                        hadIconNode = true
                        strongSelf.iconNode = nil
                        iconNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
                        iconNode.layer.animateScale(from: 1.0, to: 0.001, duration: 0.2, removeOnCompletion: false, completion: { [weak iconNode] _ in
                            iconNode?.removeFromSupernode()
                        })
                    }
                    
                    if let node = nodeToAnimateIn, hadMicrophoneNode || hadRaiseHandNode || hadIconNode {
                        node.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                        node.layer.animateScale(from: 0.001, to: 1.0, duration: 0.2)
                    }
                    
                    if !strongSelf.isExtracted && !strongSelf.animatingExtraction {
                        strongSelf.videoFadeNode.frame = CGRect(x: 0.0, y: videoSize.height - fadeHeight, width: videoSize.width, height: fadeHeight)
                        strongSelf.videoContainerNode.bounds = CGRect(origin: CGPoint(), size: videoSize)

                        if let videoNode = strongSelf.videoNode {
                            strongSelf.videoFadeNode.alpha = videoNode.alpha
                        } else {
                            strongSelf.videoFadeNode.alpha = 0.0
                        }
                        strongSelf.videoContainerNode.position = CGPoint(x: tileSize.width / 2.0, y: tileSize.height / 2.0)
                        strongSelf.videoContainerNode.cornerRadius = videoCornerRadius
                        strongSelf.videoContainerNode.transform = CATransform3DMakeScale(videoContainerScale, videoContainerScale, 1.0)
                    }
                    
                    strongSelf.highlightNode.isHidden = !item.active
                    
                    let canUpdateAvatarVisibility = !strongSelf.isExtracted && !strongSelf.animatingExtraction
                    
                    if let videoNode = videoNode {
                        let transition = ContainedViewLayoutTransition.animated(duration: 0.2, curve: .easeInOut)
                        if !strongSelf.isExtracted && !strongSelf.animatingExtraction {
                            if currentItem != nil {
                                if item.active {
                                    if strongSelf.avatarNode.alpha.isZero {
                                        strongSelf.animatingSelection = true
                                        strongSelf.videoContainerNode.layer.animateScale(from: videoContainerScale, to: 0.001, duration: 0.2)
                                        strongSelf.avatarNode.layer.animateScale(from: 0.0, to: 1.0, duration: 0.2, completion: { [weak self] _ in
                                            self?.animatingSelection = false
                                        })
                                        strongSelf.videoContainerNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: -9.0), duration: 0.2, additive: true)
                                        strongSelf.audioLevelView?.layer.animateScale(from: 0.0, to: 1.0, duration: 0.2)
                                    }
                                    transition.updateAlpha(node: videoNode, alpha: 0.0)
                                    transition.updateAlpha(node: strongSelf.videoFadeNode, alpha: 0.0)
                                    transition.updateAlpha(node: strongSelf.avatarNode, alpha: 1.0)
                                    if let audioLevelView = strongSelf.audioLevelView {
                                        transition.updateAlpha(layer: audioLevelView.layer, alpha: 1.0)
                                    }
                                } else {
                                    if !strongSelf.avatarNode.alpha.isZero {
                                        strongSelf.videoContainerNode.layer.animateScale(from: 0.001, to: videoContainerScale, duration: 0.2)
                                        strongSelf.avatarNode.layer.animateScale(from: 1.0, to: 0.001, duration: 0.2)
                                        strongSelf.audioLevelView?.layer.animateScale(from: 1.0, to: 0.001, duration: 0.2)
                                        strongSelf.videoContainerNode.layer.animatePosition(from: CGPoint(x: 0.0, y: -9.0), to: CGPoint(), duration: 0.2, additive: true)
                                    }
                                    transition.updateAlpha(node: videoNode, alpha: 1.0)
                                    transition.updateAlpha(node: strongSelf.videoFadeNode, alpha: 1.0)
                                    transition.updateAlpha(node: strongSelf.avatarNode, alpha: 0.0)
                                    if let audioLevelView = strongSelf.audioLevelView {
                                        transition.updateAlpha(layer: audioLevelView.layer, alpha: 0.0)
                                    }
                                }
                            } else {
                                if item.active {
                                    videoNode.alpha = 0.0
                                    if canUpdateAvatarVisibility {
                                        strongSelf.avatarNode.alpha = 1.0
                                    }
                                } else {
                                    videoNode.alpha = 1.0
                                    strongSelf.avatarNode.alpha = 0.0
                                }
                            }
                        }
                        
                        videoNode.updateLayout(size: videoSize, layoutMode: .fillOrFitToSquare, transition: .immediate)
                        if !strongSelf.isExtracted && !strongSelf.animatingExtraction {
                            if videoNode.supernode !== strongSelf.videoContainerNode {
                                videoNode.clipsToBounds = true
                                strongSelf.videoContainerNode.addSubnode(videoNode)
                            }
                            
                            videoNode.position = CGPoint(x: videoSize.width / 2.0, y: videoSize.height / 2.0)
                            videoNode.bounds = CGRect(origin: CGPoint(), size: videoSize)
                        }
                        
                        if let _ = currentItem, videoNodeUpdated {
                            if item.active {
                                if canUpdateAvatarVisibility {
                                    strongSelf.avatarNode.alpha = 1.0
                                }
                                videoNode.alpha = 0.0
                            } else {
                                strongSelf.avatarNode.alpha = 0.0
                                strongSelf.avatarNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2)
                                videoNode.layer.animateScale(from: 0.01, to: 1.0, duration: 0.2)
                                videoNode.alpha = 1.0
                            }
                        } else {
                            if item.active {
                                if canUpdateAvatarVisibility {
                                    strongSelf.avatarNode.alpha = 1.0
                                }
                                videoNode.alpha = 0.0
                            } else {
                                strongSelf.avatarNode.alpha = 0.0
                                videoNode.alpha = 1.0
                            }
                        }
                    } else if canUpdateAvatarVisibility {
                        strongSelf.avatarNode.alpha = 1.0
                    }
                                        
                    strongSelf.iconNode?.frame = CGRect(origin: CGPoint(), size: animationSize)
                    strongSelf.animationNode?.frame = CGRect(origin: CGPoint(), size: animationSize)
                    strongSelf.raiseHandNode?.frame = CGRect(origin: CGPoint(), size: animationSize).insetBy(dx: -6.0, dy: -6.0).offsetBy(dx: -2.0, dy: 0.0)
                    
                    strongSelf.actionButtonNode.transform = CATransform3DMakeScale(animationScale, animationScale, 1.0)
//                    strongSelf.actionButtonNode.frame = animationFrame
                    transition.updateFrame(node: strongSelf.actionButtonNode, frame: animationFrame)
                                        
                    strongSelf.updateIsHighlighted(transition: transition)
                }
            })
        }
    }
    
    var isHighlighted = false
    func updateIsHighlighted(transition: ContainedViewLayoutTransition) {

    }
    
    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)
             
        self.isHighlighted = highlighted
            
        self.updateIsHighlighted(transition: (animated && !highlighted) ? .animated(duration: 0.3, curve: .easeInOut) : .immediate)
    }
    
    override func animateInsertion(_ currentTimestamp: Double, duration: Double, short: Bool) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }
    
    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
    
    override func header() -> ListViewItemHeader? {
        return nil
    }
    
    override func updateAbsoluteRect(_ rect: CGRect, within containerSize: CGSize) {
        var rect = rect
        rect.origin.y += self.insets.top
        self.absoluteLocation = (rect, containerSize)
    }
}