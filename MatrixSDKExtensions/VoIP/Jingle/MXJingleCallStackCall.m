/*
 Copyright 2016 OpenMarket Ltd
 Copyright 2018 New Vector Ltd
 Copyright 2019 The Matrix.org Foundation C.I.C

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXJingleCallStackCall.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#import "MXTools.h"
#import "MXLog.h"

#import "MXJingleVideoView.h"
#import "MXJingleCameraCaptureController.h"
#import <WebRTC/WebRTC.h>

NSString *const kMXJingleCallWebRTCMainStreamID = @"userMedia";

typedef void (^HandleOfferBlock)(dispatch_block_t);

@interface MXJingleCallStackCall () <RTCPeerConnectionDelegate>
{
    /**
     The libjingle all purpose factory.
     */
    RTCPeerConnectionFactory *peerConnectionFactory;

    /**
     The libjingle object handling the call.
     */
    RTCPeerConnection *peerConnection;

    /**
     The media tracks.
     */
    RTCAudioTrack *localAudioTrack;
    RTCVideoTrack *localVideoTrack;
    RTCVideoTrack *remoteVideoTrack;

    /**
     The view that displays the remote video.
     */
    MXJingleVideoView *remoteJingleVideoView;

    /**
     Flag indicating if this is a video call.
     */
    BOOL isVideoCall;

    /**
     Success block for the async `startCapturingMediaWithVideo` method.
     */
    void (^onStartCapturingMediaWithVideoSuccess)(void);

    /**
     Remote ice candidates received before setting remote description for the peer connection.
     */
    NSMutableArray<RTCIceCandidate *> *cachedRemoteIceCandidates;
    
#if DEBUG
    /**
     Timer for getting stats for the peer connection.
     */
    NSTimer *statsTimer;
#endif
}

@property (nonatomic, strong) RTCVideoCapturer *videoCapturer;
@property (nonatomic, strong) MXJingleCameraCaptureController *captureController;
@property (nonatomic, strong) NSMutableArray<HandleOfferBlock> *pendingOffers;

@end

@implementation MXJingleCallStackCall
@synthesize selfVideoView, remoteVideoView, cameraPosition, delegate;

- (instancetype)initWithFactory:(RTCPeerConnectionFactory *)factory
{
    self = [super init];
    if (self)
    {
        peerConnectionFactory = factory;
        cameraPosition = AVCaptureDevicePositionFront;
        cachedRemoteIceCandidates = [NSMutableArray array];
        _pendingOffers = [NSMutableArray array];
    }
    return self;
}

- (void)startCapturingMediaWithVideo:(BOOL)video success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    onStartCapturingMediaWithVideoSuccess = success;
    isVideoCall = video;

    // Video requires views to render to before calling createLocalMediaStream
    if (!video || (selfVideoView && remoteVideoView))
    {
        [self createLocalMediaStream];
    }
    else
    {
        MXLogDebug(@"[MXJingleCallStackCall] Wait for the setting of selfVideoView and remoteVideoView before calling createLocalMediaStream");
    }
}

- (void)hold:(BOOL)hold
     success:(void (^)(NSString *sdp))success
     failure:(void (^)(NSError *))failure
{
    [peerConnection.transceivers enumerateObjectsUsingBlock:^(RTCRtpTransceiver * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        obj.sender.track.isEnabled = !hold;
        obj.receiver.track.isEnabled = !hold;
        [obj setDirection:hold ? RTCRtpTransceiverDirectionSendOnly : RTCRtpTransceiverDirectionSendRecv error:NULL];
    }];
    
    RTCMediaConstraints *mediaConstraints;
    
    if (hold)
    {
        [self.captureController stopCapture];
        mediaConstraints = self.mediaConstraintsForHoldedCall;
    }
    else
    {
        if (self->isVideoCall)
        {
            [self.captureController startCapture];
        }
        mediaConstraints = self.mediaConstraints;
    }
    
    MXWeakify(self);
    [peerConnection offerForConstraints:mediaConstraints completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
        MXStrongifyAndReturnIfNil(self);

        if (!error)
        {
            // Report this sdp back to libjingle
            [self->peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                MXLogDebug(@"[MXJingleCallStackCall] hold: setLocalDescription: error: %@", error);
                
                // Return on main thread
                dispatch_async(dispatch_get_main_queue(), ^{
                    
                    if (!error)
                    {
                        success([self sdpByFilteringHostCandidates:sdp.sdp]);
                    }
                    else
                    {
                        failure(error);
                    }
                    
                });
            }];
        }
        else
        {
            // Return on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                
                failure(error);
                
            });
        }
    }];
}

- (void)end
{
    self.videoCapturer = nil;
    [self.captureController stopCapture];
    self.captureController = nil;
    
    [peerConnection close];
    peerConnection = nil;
    
    // Reset RTC tracks, a latency was observed on avFoundationVideoSourceWithConstraints call when localVideoTrack was not reseted.
    localAudioTrack = nil;
    localVideoTrack = nil;
    remoteVideoTrack = nil;

    self.selfVideoView = nil;
    self.remoteVideoView = nil;
    
#if DEBUG
    [statsTimer invalidate];
    statsTimer = nil;
#endif
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)addTURNServerUris:(NSArray<NSString *> *)uris withUsername:(nullable NSString *)username password:(nullable NSString *)password
{
    RTCIceServer *ICEServer;

    if (uris)
    {
        ICEServer = [[RTCIceServer alloc] initWithURLStrings:uris
                                                    username:username
                                                  credential:password];

        if (!ICEServer)
        {
            MXLogDebug(@"[MXJingleCallStackCall] addTURNServerUris: Warning: Failed to create RTCICEServer with credentials %@: %@ for:\n%@", username, password, uris);
        }
    }

    RTCMediaConstraints  *constraints =
    [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil
                                          optionalConstraints:@{
                                                                @"RtpDataChannels": kRTCMediaConstraintsValueTrue
                                                                }];

    RTCConfiguration *configuration = [[RTCConfiguration alloc] init];
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    if (ICEServer)
    {
        configuration.iceServers = @[ICEServer];
    }

    // The libjingle call object can now be created
    peerConnection = [peerConnectionFactory peerConnectionWithConfiguration:configuration constraints:constraints delegate:self];
    
#if DEBUG
    statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [self->peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport * _Nonnull statistics) {
            MXLogDebug(@"[MXJingleCallStackCall] peerConnection.statistics: %@", statistics);
        }];
    }];
#endif
}

- (void)handleRemoteCandidate:(NSDictionary<NSString *, NSObject *> *)candidate
{
    RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc] initWithSdp:(NSString *)candidate[@"candidate"]
                                                           sdpMLineIndex:[(NSNumber *)candidate[@"sdpMLineIndex"] intValue]
                                                                  sdpMid:(NSString *)candidate[@"sdpMid"]];

    // Ice candidates have to be added after the remote description has been set
    if (!peerConnection.remoteDescription)
    {
        // Cache ice candidates until remote description is set
        [cachedRemoteIceCandidates addObject:iceCandidate];
    }
    else
    {
        [peerConnection addIceCandidate:iceCandidate];
    }
}


#pragma mark - Incoming call
- (void)handleOffer:(NSString *)sdpOffer success:(void (^)(void))success failure:(void (^)(NSError *error))failure
{
    HandleOfferBlock handleOfferBlock = ^(dispatch_block_t completion){
        RTCSessionDescription *sessionDescription = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdpOffer];
        MXWeakify(self);
        MXLogDebug(@"[MXJingleCallStackCall] handleOffer: willSetRemoteDescription with peerConnection: %@ sdp: %@",
                   self->peerConnection,
                   sdpOffer);
        [self->peerConnection setRemoteDescription:sessionDescription completionHandler:^(NSError * _Nullable error) {
            MXLogDebug(@"[MXJingleCallStackCall] handleOffer: setRemoteDescription: error: %@", error);
            
            // Return on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                MXStrongifyAndReturnIfNil(self);
                
                if (!error)
                {
                    // Add cached ice candidates after setting remote description
                    for (RTCIceCandidate *iceCandidate in self->cachedRemoteIceCandidates)
                    {
                        [self->peerConnection addIceCandidate:iceCandidate];
                    }
                    [self->cachedRemoteIceCandidates removeAllObjects];
                    
                    success();
                    if (completion)
                    {
                        completion();
                    }
                }
                else
                {
                    failure(error);
                    if (completion)
                    {
                        completion();
                    }
                }
                
            });
        }];
    };
    
    if (peerConnection.signalingState == RTCSignalingStateStable)
    {
        MXLogDebug(@"[MXJingleCallStackCall] handleOffer: executing block right away")
        handleOfferBlock(nil);
    }
    else
    {
        MXLogDebug(@"[MXJingleCallStackCall] handleOffer: saving block to be run in future")
        [_pendingOffers addObject:handleOfferBlock];
    }
}

- (void)createAnswer:(void (^)(NSString *))success failure:(void (^)(NSError *))failure
{
    MXWeakify(self);
    [peerConnection answerForConstraints:self.mediaConstraints completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
        MXStrongifyAndReturnIfNil(self);

        // Return on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (!error)
            {
                MXWeakify(self);
                // Report this sdp back to libjingle
                [self->peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                    MXStrongifyAndReturnIfNil(self);
                    
                    MXLogDebug(@"[MXJingleCallStackCall] createAnswer: setLocalDescription: error: %@", error);
                    
                    // Return on main thread
                    dispatch_async(dispatch_get_main_queue(), ^{
                        
                        if (!error)
                        {
                            success([self sdpByFilteringHostCandidates:sdp.sdp]);
                        }
                        else
                        {
                            failure(error);
                        }
                        
                    });
                    
                    //  check we can consider this call as held, after setting local description
                    [self checkTheCallIsRemotelyOnHold];
                    
                }];
            }
            else
            {
                failure(error);
            }
            
        });
    }];
}

#pragma mark - Outgoing call

- (void)createOffer:(void (^)(NSString *sdp))success failure:(void (^)(NSError *))failure
{
    MXWeakify(self);
    [peerConnection offerForConstraints:self.mediaConstraints completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
        MXStrongifyAndReturnIfNil(self);

        // Return on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (!error)
            {
                // Report this sdp back to libjingle
                [self->peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                    MXLogDebug(@"[MXJingleCallStackCall] createOffer: setLocalDescription: error: %@", error);
                    
                    // Return on main thread
                    dispatch_async(dispatch_get_main_queue(), ^{
                        
                        if (!error)
                        {
                            success([self sdpByFilteringHostCandidates:sdp.sdp]);
                        }
                        else
                        {
                            failure(error);
                        }
                        
                    });
                }];
            }
            else
            {
                failure(error);
            }
            
        });
        
    }];
}

- (void)handleAnswer:(NSString *)sdp success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    RTCSessionDescription *sessionDescription = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:sdp];
    
    MXWeakify(self);
    [peerConnection setRemoteDescription:sessionDescription completionHandler:^(NSError * _Nullable error) {
        MXStrongifyAndReturnIfNil(self);
        
        MXLogDebug(@"[MXJingleCallStackCall] handleAnswer: setRemoteDescription: error: %@", error);
        
        // Return on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (!error)
            {
                // Add cached ice candidates after setting remote description
                for (RTCIceCandidate *iceCandidate in self->cachedRemoteIceCandidates)
                {
                    [self->peerConnection addIceCandidate:iceCandidate];
                }
                [self->cachedRemoteIceCandidates removeAllObjects];
                
                success();
            }
            else
            {
                failure(error);
            }
            
        });
        
        //  check we can consider this call as held, after handling the remote's answer
        [self checkTheCallIsRemotelyOnHold];
        
    }];
}

#pragma mark - DTMF

- (BOOL)canSendDTMF
{
    return [self dtmfSender];
}

- (id<RTCDtmfSender>)dtmfSender
{
    for(RTCRtpSender *sender in peerConnection.senders)
    {
        if ([sender.track.kind isEqualToString: kRTCMediaStreamTrackKindAudio] && sender.dtmfSender.canInsertDtmf) {
            return sender.dtmfSender;
        }
    }
    return nil;
}

- (BOOL)sendDTMF:(NSString *)tones
{
    if (!self.canSendDTMF)
    {
        //  cannot send DTMF
        return NO;
    }
    
    return [[self dtmfSender] insertDtmf:tones duration:.1 interToneGap:0.07];
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeConnectionState:(RTCPeerConnectionState)newState
{
    MXLogDebug(@"[MXJingleCallStackCall] didChangeConnectionState: %tu", newState);
    
    switch (newState)
    {
        case RTCPeerConnectionStateConnected:
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate callStackCallDidConnect:self];
            });
            break;
        }
        case RTCPeerConnectionStateFailed:
        {
            // ICE discovery has failed or the connection has dropped
            dispatch_async(dispatch_get_main_queue(), ^{

                [self.delegate callStackCall:self onError:nil];
                
            });
            break;
        }

        default:
            break;
    }
}

// Triggered when the SignalingState changed.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
 didChangeSignalingState:(RTCSignalingState)stateChanged
{
    MXLogDebug(@"[MXJingleCallStackCall] didChangeSignalingState: %tu", stateChanged);
    
    if (stateChanged == RTCSignalingStateStable)
    {
        //  process pending offers
        dispatch_group_t group = dispatch_group_create();
        for (HandleOfferBlock block in _pendingOffers)
        {
            MXLogDebug(@"[MXJingleCallStackCall] didChangeSignalingState: executing pre-saved block")
            dispatch_group_enter(group);
            block(^{
                dispatch_group_leave(group);
            });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [self.pendingOffers removeAllObjects];
        });
    }
}

// Triggered when media is received on a new stream from remote peer.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
          didAddStream:(RTCMediaStream *)stream
{
    MXLogDebug(@"[MXJingleCallStackCall] didAddStream");
}

// Triggered when a remote peer close a stream.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
       didRemoveStream:(RTCMediaStream *)stream
{
    MXLogDebug(@"[MXJingleCallStackCall] didRemoveStream");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddReceiver:(RTCRtpReceiver *)rtpReceiver streams:(NSArray<RTCMediaStream *> *)mediaStreams
{
    MXLogDebug(@"[MXJingleCallStackCall] didAddReceiver");
    
    if ([rtpReceiver.track.kind isEqualToString:kRTCMediaStreamTrackKindVideo])
    {
        // This is mandatory to keep a reference on the video track
        // Else the video does not display in self.remoteVideoView
        remoteVideoTrack = (RTCVideoTrack *)rtpReceiver.track;
        
        MXWeakify(self);
        dispatch_async(dispatch_get_main_queue(), ^{
            MXStrongifyAndReturnIfNil(self);

            // Use self.remoteVideoView as a container of a RTCEAGLVideoView
            self->remoteJingleVideoView = [[MXJingleVideoView alloc] initWithContainerView:self.remoteVideoView];
            [self->remoteVideoTrack addRenderer:self->remoteJingleVideoView];
        });
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveReceiver:(RTCRtpReceiver *)rtpReceiver
{
    MXLogDebug(@"[MXJingleCallStackCall] didRemoveReceiver");
}

// Triggered when renegotiation is needed, for example the ICE has restarted.
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection
{
    MXLogDebug(@"[MXJingleCallStackCall] peerConnectionShouldNegotiate");
}

// Called any time the ICEConnectionState changes.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
didChangeIceConnectionState:(RTCIceConnectionState)newState
{
    MXLogDebug(@"[MXJingleCallStackCall] didChangeIceConnectionState: %@", @(newState));
}

// Called any time the ICEGatheringState changes.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
didChangeIceGatheringState:(RTCIceGatheringState)newState
{
    MXLogDebug(@"[MXJingleCallStackCall] didChangeIceGatheringState: %@", @(newState));
}

// New Ice candidate have been found.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
didGenerateIceCandidate:(RTCIceCandidate *)candidate
{
    MXLogDebug(@"[MXJingleCallStackCall] didGenerateIceCandidate: %@", candidate);

    if ([self isHostCandidateSdp:candidate.sdp])
    {
        MXLogDebug(@"[MXJingleCallStackCall] didGenerateIceCandidate: Filter out host candidate");
        return;
    }

    NSString *candidateSdp = [self candidateSdpByHidingRelatedAddress:candidate.sdp];

    // Forward found ICE candidates
    dispatch_async(dispatch_get_main_queue(), ^{
        
        [self.delegate callStackCall:self onICECandidateWithSdpMid:candidate.sdpMid sdpMLineIndex:candidate.sdpMLineIndex candidate:candidateSdp];
        
    });
}

// Called when a group of local Ice candidates have been removed.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates;
{
    MXLogDebug(@"[MXJingleCallStackCall] didRemoveIceCandidates");
}

// New data channel has been opened.
- (void)peerConnection:(RTCPeerConnection*)peerConnection
    didOpenDataChannel:(RTCDataChannel*)dataChannel
{
    MXLogDebug(@"[MXJingleCallStackCall] didOpenDataChannel");
}


#pragma mark - Properties

- (void)setSelfVideoView:(nullable UIView *)selfVideoView2
{
    selfVideoView = selfVideoView2;
    
    [self checkStartGetCaptureSourcesForVideo];
}

- (void)setRemoteVideoView:(nullable UIView *)remoteVideoView2
{
    remoteVideoView = remoteVideoView2;
    
    [self checkStartGetCaptureSourcesForVideo];
}

- (UIDeviceOrientation)selfOrientation
{
    // @TODO: Hmm
    return UIDeviceOrientationUnknown;
}

- (void)setSelfOrientation:(UIDeviceOrientation)selfOrientation
{
    // Force recomputing of the remote video aspect ratio
    [remoteJingleVideoView setNeedsLayout];
}

- (BOOL)audioMuted
{
    return !localAudioTrack.isEnabled;
}

- (void)setAudioMuted:(BOOL)audioMuted
{
    localAudioTrack.isEnabled = !audioMuted;
}

- (BOOL)videoMuted
{
    return !localVideoTrack.isEnabled;
}

- (void)setVideoMuted:(BOOL)videoMuted
{
    localVideoTrack.isEnabled = !videoMuted;
}

- (void)setCameraPosition:(AVCaptureDevicePosition)theCameraPosition
{
    cameraPosition = theCameraPosition;
    
    if (localVideoTrack)
    {
        [self fixMirrorOnSelfVideoView];
    }
    
    self.captureController.cameraPosition = theCameraPosition;
}

#pragma mark - Private methods

/**
 Tell if a candidate is a host one, holding an address of the device itself.

 Host candidates are never sent to the other party: they carry the local, VPN and IPv6 addresses
 of the device. Filtering happens on the candidates themselves rather than through the WebRTC host
 filter, because libwebrtc keeps host candidates that hold a public IP address even when that filter
 is on, considering them equivalent to server reflexive ones, which leaks every IPv6 address.

 @param candidateSdp the SDP of a single ICE candidate.
 @return YES if the candidate is a host one.
 */
- (BOOL)isHostCandidateSdp:(NSString *)candidateSdp
{
    return [candidateSdp rangeOfString:@" typ host" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

/**
 Hide the address a candidate was derived from.

 The rel-addr and rel-port fields expose the local IP address of the device for a server reflexive
 candidate, and its public IP address for a relay one. They are informational, ICE does not use them
 to establish a connection, so their values are replaced by the unspecified address and the discard
 port. The address the candidate is reachable at is left untouched: changing it breaks the call.

 @param candidateSdp the SDP of a single ICE candidate, with or without its `a=` prefix.
 @return the candidate sdp with hidden related address.
 */
- (NSString *)candidateSdpByHidingRelatedAddress:(NSString *)candidateSdp
{
    if (candidateSdp.length == 0)
    {
        return candidateSdp;
    }

    NSMutableArray<NSString *> *tokens = [[candidateSdp componentsSeparatedByString:@" "] mutableCopy];

    //  Look the fields up by name, the candidate attribute holds optional fields and extensions
    NSUInteger relatedAddressIndex = [tokens indexOfObject:@"raddr"];
    if (relatedAddressIndex != NSNotFound && relatedAddressIndex + 1 < tokens.count)
    {
        NSString *relatedAddress = tokens[relatedAddressIndex + 1];
        BOOL isIPv6 = [relatedAddress containsString:@":"];
        tokens[relatedAddressIndex + 1] = isIPv6 ? @"::" : @"0.0.0.0";
    }

    NSUInteger relatedPortIndex = [tokens indexOfObject:@"rport"];
    if (relatedPortIndex != NSNotFound && relatedPortIndex + 1 < tokens.count)
    {
        //  9 is the discard port, the placeholder port SDP uses for a media line that carries no address
        tokens[relatedPortIndex + 1] = @"9";
    }

    return [tokens componentsJoinedByString:@" "];
}

/**
 Remove the host candidates from a session description.

 Candidates gathered before the offer or the answer is created are embedded into it, so they are
 filtered the same way as the trickled ones. A connection line pointing to a filtered address is
 reset to the unspecified address used by trickle ICE, otherwise it would leak it back.

 @param sdp a session description.
 @return the sdp without its host candidate lines.
 */
- (NSString *)sdpByFilteringHostCandidates:(NSString *)sdp
{
    if (sdp.length == 0)
    {
        return sdp;
    }

    NSMutableArray<NSString *> *keptLines = [NSMutableArray array];
    NSMutableSet<NSString *> *filteredAddresses = [NSMutableSet set];

    for (NSString *line in [sdp componentsSeparatedByString:@"\n"])
    {
        if ([line hasPrefix:@"a=candidate:"])
        {
            if ([self isHostCandidateSdp:line])
            {
                MXLogDebug(@"[MXJingleCallStackCall] sdpByFilteringHostCandidates: Filter out host candidate");

                //  `a=candidate:<foundation> <component> <transport> <priority> <address> <port> …`
                NSArray<NSString *> *fields = [line componentsSeparatedByString:@" "];
                if (fields.count > 4)
                {
                    [filteredAddresses addObject:fields[4]];
                }
                continue;
            }

            [keptLines addObject:[self candidateSdpByHidingRelatedAddress:line]];
            continue;
        }

        [keptLines addObject:line];
    }

    if (filteredAddresses.count)
    {
        for (NSUInteger index = 0; index < keptLines.count; index++)
        {
            NSString *line = keptLines[index];
            if (![line hasPrefix:@"c=IN "])
            {
                continue;
            }

            //  `c=IN <IP4|IP6> <address>`
            NSArray<NSString *> *fields = [[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@" "];
            if (fields.count == 3 && [filteredAddresses containsObject:fields[2]])
            {
                MXLogDebug(@"[MXJingleCallStackCall] sdpByFilteringHostCandidates: Reset connection line");
                NSString *lineEnding = [line hasSuffix:@"\r"] ? @"\r" : @"";
                keptLines[index] = [NSString stringWithFormat:@"c=IN IP4 0.0.0.0%@", lineEnding];
            }
        }
    }

    return [keptLines componentsJoinedByString:@"\n"];
}

- (void)checkTheCallIsRemotelyOnHold
{
    NSArray<RTC_OBJC_TYPE(RTCRtpTransceiver) *> *activeReceivers = [self->peerConnection.transceivers filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RTC_OBJC_TYPE(RTCRtpTransceiver) *transceiver, NSDictionary<NSString *,id> * _Nullable bindings) {
        
        RTCRtpTransceiverDirection direction = RTCRtpTransceiverDirectionStopped;
        if ([transceiver currentDirection:&direction])
        {
            if (direction == RTCRtpTransceiverDirectionInactive ||
                direction == RTCRtpTransceiverDirectionRecvOnly ||  //  remote party can set a hold tone with 'sendonly'
                direction == RTCRtpTransceiverDirectionStopped)
            {
                return NO;
            }
        }
        
        return YES;
    }]];
    
    if (peerConnection.connectionState == RTCPeerConnectionStateConnected)
    {
        if (activeReceivers.count == 0)
        {
            //  if there is no active receivers (on the other party) left, we can say this call is holded
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate callStackCallDidRemotelyHold:self];
            });
        }
        else
        {
            //  otherwise we can say this call resumed after a remote hold
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate callStackCallDidConnect:self];
            });
        }
    }
}

//  Not used for now, may be in future
- (BOOL)isHoldOffer:(NSString *)sdpOffer
{
    NSUInteger numberOfAudioTracks = [self numberOfMatchesOfKeyword:@"m=audio" inString:sdpOffer];
    NSUInteger numberOfVideoTracks = [self numberOfMatchesOfKeyword:@"m=video" inString:sdpOffer];

    if (numberOfAudioTracks == 0 && numberOfVideoTracks == 0)
    {
        //  no audio or video tracks
        return YES;
    }

    NSUInteger numberOfInactiveTracks = [self numberOfMatchesOfKeyword:@"a=inactive" inString:sdpOffer];
    
    return (numberOfAudioTracks + numberOfVideoTracks) == numberOfInactiveTracks;
}

- (NSUInteger)numberOfMatchesOfKeyword:(NSString *)keyword inString:(NSString *)string
{
    NSError *error = NULL;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:keyword
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:&error];
    return [regex numberOfMatchesInString:string
                                  options:0
                                    range:NSMakeRange(0, [string length])];
}

- (RTCMediaConstraints *)mediaConstraints
{
    
    return [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{
        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
        kRTCMediaConstraintsOfferToReceiveVideo: (isVideoCall ? kRTCMediaConstraintsValueTrue : kRTCMediaConstraintsValueFalse)
    }
                                                 optionalConstraints:nil];
}

- (RTCMediaConstraints *)mediaConstraintsForHoldedCall
{
    return [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{
        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
        kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse
    }
                                                 optionalConstraints:nil];
}

- (void)createLocalMediaStream
{
    // Set up audio
    localAudioTrack = [self createLocalAudioTrack];
    
    [peerConnection addTrack:localAudioTrack streamIds:@[kMXJingleCallWebRTCMainStreamID]];
    
    // And video
    if (isVideoCall)
    {
        localVideoTrack = [self createLocalVideoTrack];
        // Create a video track and add it to the media stream
        if (localVideoTrack)
        {
            [peerConnection addTrack:localVideoTrack streamIds:@[kMXJingleCallWebRTCMainStreamID]];
            
            // Display the self view
            // Use selfVideoView as a container of a RTCEAGLVideoView
            MXJingleVideoView *renderView = [[MXJingleVideoView alloc] initWithContainerView:self.selfVideoView];
            [self startVideoCaptureWithRenderer:renderView];
        }
    }
    
    if (onStartCapturingMediaWithVideoSuccess)
    {
        onStartCapturingMediaWithVideoSuccess();
        onStartCapturingMediaWithVideoSuccess = nil;
    }
}

- (RTCAudioTrack*)createLocalAudioTrack
{
    RTCMediaConstraints *mediaConstraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    RTCAudioSource *localAudioSource = [peerConnectionFactory audioSourceWithConstraints:mediaConstraints];
    NSString *trackId = [NSString stringWithFormat:@"%@a0", kMXJingleCallWebRTCMainStreamID];
    return [peerConnectionFactory audioTrackWithSource:localAudioSource trackId:trackId];
}

- (RTCVideoTrack*)createLocalVideoTrack
{
    RTCVideoSource *localVideoSource = [peerConnectionFactory videoSource];
    
    self.videoCapturer = [self createVideoCapturerWithVideoSource:localVideoSource];
    
    NSString *trackId = [NSString stringWithFormat:@"%@v0", kMXJingleCallWebRTCMainStreamID];
    return [peerConnectionFactory videoTrackWithSource:localVideoSource trackId:trackId];
}

- (RTCVideoCapturer*)createVideoCapturerWithVideoSource:(RTCVideoSource*)videoSource
{
    RTCVideoCapturer *videoCapturer;
    
    #if !TARGET_OS_SIMULATOR
    videoCapturer = [[RTCCameraVideoCapturer alloc] initWithDelegate:videoSource];
    #endif
    
    return videoCapturer;
}

- (void)startVideoCaptureWithRenderer:(id<RTCVideoRenderer>)videoRenderer
{
    if (!self.videoCapturer || ![self.videoCapturer isKindOfClass:[RTCCameraVideoCapturer class]])
    {
        return;
    }
    
    RTCCameraVideoCapturer *cameraVideoCapturer = (RTCCameraVideoCapturer*)self.videoCapturer;
    
    self.captureController = [[MXJingleCameraCaptureController alloc] initWithCapturer:cameraVideoCapturer];
    
    [localVideoTrack addRenderer:videoRenderer];
    
    [self.captureController startCapture];
}

- (void)checkStartGetCaptureSourcesForVideo
{
    if (onStartCapturingMediaWithVideoSuccess && selfVideoView && remoteVideoView)
    {
        MXLogDebug(@"[MXJingleCallStackCall] selfVideoView and remoteVideoView are set. Call createLocalMediaStream");

        [self createLocalMediaStream];
    }
}

- (void)fixMirrorOnSelfVideoView
{
    if (cameraPosition == AVCaptureDevicePositionFront)
    {
        // Apply a left to right flip on the self video view on the front camera preview
        // so that the user sees himself as in a mirror
        selfVideoView.transform = CGAffineTransformMakeScale(-1.0, 1.0);
    }
    else
    {
        selfVideoView.transform = CGAffineTransformIdentity;
    }
}

@end
