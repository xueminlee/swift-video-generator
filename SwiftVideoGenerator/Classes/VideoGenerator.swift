//
//  VideoGenerator.swift
//  VideoGeneration
//
//  Created by DevLabs BG on 7/11/17.
//  Copyright © 2017 Devlabs. All rights reserved.
//

import UIKit
import AVFoundation

public class VideoGenerator: NSObject {
  
  // MARK: - Singleton properties
  
  open class var current: VideoGenerator {
    struct Static {
      static var instance = VideoGenerator()
    }
    
    return Static.instance
  }
  
  // MARK: - Static properties
  
  /// Public enum type to represent the video generator's available modes
  ///
  /// - single: a single type generates a video from a single image and audio files
  /// - multiple: a multiple type generates a video with multiple image/audio combinations (the first image/audio pair is combined, played then switched for the next image/audio pair)
  public enum VideoGeneratorType: Int {
    case single, multiple, singleAudioMultipleImage
    
    init() {
      self = .single
    }
  }
  
  // MARK: - Public properties
  
  /// public property to set the name of the finished video file
  open var fileName = "movie"
  
  /// public property to set a multiple type video's background color
  open var videoBackgroundColor: UIColor = UIColor.black
  
  /// public property to set a width to scale the image to before generating a video (used only with .single type video generation; preferred scale: 800/1200)
  open var scaleWidth: CGFloat?
  
  /// public property to indicate if the images fed into the generator should be resized to appropriate video ratio 1200 x 1920
  open var shouldOptimiseImageForVideo: Bool = true
  
  /// public property to set the maximum length of a video
  open var maxVideoLengthInSeconds: Double?
  
  // MARK: - Public methods
  
  /**
   Public method to start a video generation
   
   - parameter progress: A block which will track the progress of the generation
   - parameter success:  A block which will be called after successful generation of video
   - parameter failure:  A blobk which will be called on a failure durring the generation of the video
   */
  open func generate(withImages _images: [UIImage], andAudios _audios: [URL], andType _type: VideoGeneratorType, _ progress: @escaping ((Progress) -> Void), success: @escaping ((URL) -> Void), failure: @escaping ((Error) -> Void)) {
    
    VideoGenerator.current.setup(withImages: _images, andAudios: _audios, andType: _type)
    
    /// define the input and output size of the video which will be generated by taking the first image's size
    if let firstImage = VideoGenerator.current.images.first {
      VideoGenerator.current.minSize = firstImage.size
    }
    
    let inputSize = VideoGenerator.current.minSize
    let outputSize = VideoGenerator.current.minSize
    
    /// check if the documents directory can be accessed
    if let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
      
      /// generate a video output url
      let videoOutputURL = URL(fileURLWithPath: documentsPath).appendingPathComponent("test.m4v")
      
      do {
        if FileManager.default.fileExists(atPath: videoOutputURL.path) {
          
          /// try to delete the old generated video
          try FileManager.default.removeItem(at: videoOutputURL)
        }
      } catch { }
      
      do {
        /// try to create an asset writer for videos pointing to the video url
        try VideoGenerator.current.videoWriter = AVAssetWriter(outputURL: videoOutputURL, fileType: AVFileType.mp4)
      } catch {
        VideoGenerator.current.videoWriter = nil
        failure(error)
      }
      
      /// check if the writer is instantiated successfully
      if let videoWriter = VideoGenerator.current.videoWriter {
        
        /// create the basic video settings
        let videoSettings: [String : AnyObject] = [
          AVVideoCodecKey  : AVVideoCodecH264 as AnyObject,
          AVVideoWidthKey  : outputSize.width as AnyObject,
          AVVideoHeightKey : outputSize.height as AnyObject,
          ]
        
        /// create a video writter input
        let videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings)
        
        /// create setting for the pixel buffer
        let sourceBufferAttributes: [String : AnyObject] = [
          (kCVPixelBufferPixelFormatTypeKey as String): Int(kCVPixelFormatType_32ARGB) as AnyObject,
          (kCVPixelBufferWidthKey as String): Float(inputSize.width) as AnyObject,
          (kCVPixelBufferHeightKey as String):  Float(inputSize.height) as AnyObject,
          (kCVPixelBufferCGImageCompatibilityKey as String): NSNumber(value: true),
          (kCVPixelBufferCGBitmapContextCompatibilityKey as String): NSNumber(value: true)
        ]
        
        /// create pixel buffer for the input writter and the pixel buffer settings
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput, sourcePixelBufferAttributes: sourceBufferAttributes)
        
        /// check if an input can be added to the asset
        assert(videoWriter.canAdd(videoWriterInput))
        
        /// add the input writter to the video asset
        videoWriter.add(videoWriterInput)
        
        /// check if a write session can be executed
        if videoWriter.startWriting() {
          
          /// if it is possible set the start time of the session (current at the begining)
          videoWriter.startSession(atSourceTime: kCMTimeZero)
          
          /// check that the pixel buffer pool has been created
          assert(pixelBufferAdaptor.pixelBufferPool != nil)
          
          /// create/access separate queue for the generation process
          let media_queue = DispatchQueue(label: "mediaInputQueue", attributes: [])
          
          /// start video generation on a separate queue
          videoWriterInput.requestMediaDataWhenReady(on: media_queue, using: { () -> Void in
            
            /// set up preliminary properties for the image count, frame count and the video elapsed time
            let numImages = VideoGenerator.current.images.count
            var frameCount = 0
            var elapsedTime: Double = 0
            
            /// calculate the frame duration by dividing the full video duration by the number of images and rounding up the number
            let frameDuration = CMTime(seconds: ceil(Double(VideoGenerator.current.duration / Double(VideoGenerator.current.images.count))), preferredTimescale: 1)
            let currentProgress = Progress(totalUnitCount: Int64(VideoGenerator.current.images.count))
            
            /// declare a temporary array to hold all as of yet unused images
            var remainingPhotos = [UIImage](VideoGenerator.current.images)
            
            var nextStartTimeForFrame: CMTime! = CMTime(seconds: 0, preferredTimescale: 1)
            var imageForVideo: UIImage!
            
            /// if the input writer is ready and we have not yet used all imaged
            while (videoWriterInput.isReadyForMoreMediaData && frameCount < numImages) {
              
              if VideoGenerator.current.type == .single {
                /// pick the next photo to be loaded
                imageForVideo = remainingPhotos.remove(at: 0)
                
                /// calculate the beggining time of the next frame; if the frame is the first, the start time is 0, if not, the time is the number of the frame multiplied by the frame duration in seconds
                nextStartTimeForFrame = frameCount == 0 ? CMTime(seconds: 0, preferredTimescale: 1) : CMTime(seconds: Double(frameCount) * frameDuration.seconds, preferredTimescale: 1)
              } else {
                /// get the right photo from the array
                imageForVideo = VideoGenerator.current.images[frameCount]
                
                if VideoGenerator.current.type == .multiple {
                  /// calculate the start of the frame; if the frame is the first, the start time is 0, if not, get the already elapsed time
                  nextStartTimeForFrame = frameCount == 0 ? CMTime(seconds: 0, preferredTimescale: 1) : CMTime(seconds: Double(elapsedTime), preferredTimescale: 1)
                  
                  /// add the max between the audio duration time or a minimum duration to the elapsed time
                  elapsedTime += VideoGenerator.current.audioDurations[frameCount] <= 1 ? VideoGenerator.current.minSingleVideoDuration : VideoGenerator.current.audioDurations[frameCount]
                } else {
                  nextStartTimeForFrame = frameCount == 0 ? CMTime(seconds: 0, preferredTimescale: 600) : CMTime(seconds: Double(elapsedTime), preferredTimescale: 600)
                  
                  let audio_Time = VideoGenerator.current.audioDurations[0]
                  let total_Images = VideoGenerator.current.images.count
                  elapsedTime += audio_Time / Double(total_Images)
                }
              }
              
              /// append the image to the pixel buffer at the right start time
              if !VideoGenerator.current.appendPixelBufferForImage(imageForVideo, pixelBufferAdaptor: pixelBufferAdaptor, presentationTime: nextStartTimeForFrame) {
                failure(VideoGeneratorError(error: .kFailedToAppendPixelBufferError))
              }
              
              // increise the frame count
              frameCount += 1
              
              currentProgress.completedUnitCount = Int64(frameCount)
              
              // after each successful append of an image track the current progress
              progress(currentProgress)
            }
            
            // after all images are appended the writting shoul be marked as finished
            videoWriterInput.markAsFinished()
            
            if let _maxLength = self.maxVideoLengthInSeconds {
              videoWriter.endSession(atSourceTime: CMTime(seconds: _maxLength, preferredTimescale: 1))
            }
            
            // the completion is made with a completion handler which will return the url of the generated video or an error
            videoWriter.finishWriting { () -> Void in
              /// if the writing is successfull, go on to merge the video with the audio files
              VideoGenerator.current.mergeAudio(withVideoURL: videoOutputURL, success: { (videoURL) in
                print("finished")
                success(videoURL)
              }, failure: { (error) in
                failure(error)
              })
              
              VideoGenerator.current.videoWriter = nil
            }
          })
        } else {
          failure(VideoGeneratorError(error: .kFailedToStartAssetWriterError))
        }
      } else {
        failure(VideoGeneratorError(error: .kFailedToStartAssetWriterError))
      }
    } else {
      failure(VideoGeneratorError(error: .kFailedToFetchDirectory))
    }
  }
  
  /// Method to reverse a video clip
  ///
  /// - Parameters:
  ///   - videoURL: the file's URL
  ///   - success: success completion block
  ///   - failure: failure completion block
  open func reverseClip(videoURL: URL, andFileName fileName: String?, success: @escaping ((URL) -> Void), failure: @escaping ((Error) -> Void)) {
    let media_queue = DispatchQueue(label: "mediaInputQueue", attributes: [])

    media_queue.async {
      let acceptableVideoExtensions = ["mov", "mp4", "m4v"]
      
      if !videoURL.absoluteString.contains(".DS_Store") && acceptableVideoExtensions.contains(videoURL.pathExtension) {
        let _fileName = fileName == nil ? "reversedClip" : fileName!
        
        var completeMoviePath: URL?
        let videoAsset: AVAsset! = AVURLAsset(url: videoURL)
        var videoSize = CGSize.zero
        
        if let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
          /// create a path to the video file
          completeMoviePath = URL(fileURLWithPath: documentsPath).appendingPathComponent("\(String(describing: _fileName)).m4v")
          
          if let completeMoviePath = completeMoviePath {
            if FileManager.default.fileExists(atPath: completeMoviePath.path) {
              do {
                /// delete an old duplicate file
                try FileManager.default.removeItem(at: completeMoviePath)
              } catch {
                failure(error)
              }
            }
          }
        } else {
          failure(VideoGeneratorError(error: .kFailedToFetchDirectory))
        }
        
        if let completeMoviePath = completeMoviePath {
          
          if let firstAssetTrack = videoAsset.tracks(withMediaType: .video).first {
            let orientation = videoAsset.videoOrientation()
            
            if orientation.orientation == .portrait {
              videoSize = CGSize(width: firstAssetTrack.naturalSize.height, height: firstAssetTrack.naturalSize.width)
            } else {
              videoSize = firstAssetTrack.naturalSize
            }
          }
          
          /// create the basic video settings
          let videoSettings: [String : AnyObject] = [
            AVVideoCodecKey  : AVVideoCodecH264 as AnyObject,
            AVVideoWidthKey  : videoSize.width as AnyObject,
            AVVideoHeightKey : videoSize.height as AnyObject,
            ]
          
          /// create setting for the pixel buffer
          let sourceBufferAttributes: [String : AnyObject] = [
            (kCVPixelBufferPixelFormatTypeKey as String): Int(kCVPixelFormatType_32ARGB) as AnyObject,
            (kCVPixelBufferWidthKey as String): Float(videoSize.width) as AnyObject,
            (kCVPixelBufferHeightKey as String):  Float(videoSize.height) as AnyObject,
            (kCVPixelBufferCGImageCompatibilityKey as String): NSNumber(value: true),
            (kCVPixelBufferCGBitmapContextCompatibilityKey as String): NSNumber(value: true)
          ]
          
          var writer: AVAssetWriter!
          
          do {
            let reader = try AVAssetReader(asset: videoAsset)
            
            if let assetVideoTrack = videoAsset.tracks(withMediaType: .video).first {
              
              let readerOutput = AVAssetReaderTrackOutput(track: assetVideoTrack, outputSettings: sourceBufferAttributes)
              
              assert(reader.canAdd(readerOutput))
              reader.add(readerOutput)
              
              if reader.startReading() {
                
                var samples: [CMSampleBuffer] = []
                
                while let sample = readerOutput.copyNextSampleBuffer() {
                  samples.append(sample)
                }
                
                reader.cancelReading()
                
                if samples.count > 1 {
                  
                  writer = try AVAssetWriter(outputURL: completeMoviePath, fileType: .m4v)
                  let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                  writerInput.expectsMediaDataInRealTime = false
                  
                  let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
                  
                  assert(writer.canAdd(writerInput))
                  
                  writer.add(writerInput)
                  
                  if writer.startWriting() {
                    
                    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(samples[0]))
                    
                    assert(pixelBufferAdaptor.pixelBufferPool != nil)
                    
                    for (index, sample) in samples.enumerated() {
                      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                      let imageBufferRef: CVPixelBuffer = CMSampleBufferGetImageBuffer(samples[samples.count - index - 1])!
                      
                      while (!writerInput.isReadyForMoreMediaData) {
                        Thread.sleep(forTimeInterval: 0.05)
                      }
                      
                      pixelBufferAdaptor.append(imageBufferRef, withPresentationTime: presentationTime)
                    }
                    
                    writerInput.markAsFinished()
                    
                    DispatchQueue.main.async {
                      writer.finishWriting(completionHandler: {
                        success(completeMoviePath)
                      })
                    }
                  }
                } else {
                  DispatchQueue.main.async {
                    failure(VideoGeneratorError(error: .kFailedToReadProvidedClip))
                  }
                }
              } else {
                DispatchQueue.main.async {
                  failure(VideoGeneratorError(error: .kFailedToStartReader))
                }
              }
            }
          } catch {
            DispatchQueue.main.async {
              failure(error)
            }
          }
        } else {
          DispatchQueue.main.async {
            failure(VideoGeneratorError(error: .kFailedToFetchDirectory))
          }
        }
      } else {
        DispatchQueue.main.async {
          failure(VideoGeneratorError(error: .kUnsupportedVideoType))
        }
      }
    }
  }
  
  /// Method to merge multiple videos
  ///
  /// - Parameters:
  ///   - videoURLs: the videos to merge URLs
  ///   - fileName: the name of the finished merged video file
  ///   - success: success block - returns the finished video url path
  ///   - failure: failure block - returns the error that caused the failure
  open class func mergeMovies(videoURLs: [URL], andFileName fileName: String, success: @escaping ((URL) -> Void), failure: @escaping ((Error) -> Void)) {
    let acceptableVideoExtensions = ["mov", "mp4", "m4v"]
    let _videoURLs = videoURLs.filter({ !$0.absoluteString.contains(".DS_Store") && acceptableVideoExtensions.contains($0.pathExtension) })
    let _fileName = fileName == "" ? "mergedMovie" : fileName
    
    /// guard against missing URLs
    guard !_videoURLs.isEmpty else {
      failure(VideoGeneratorError(error: .kMissingVideoURLs))
      return
    }
    
    var videoAssets: [AVURLAsset] = []
    var completeMoviePath: URL?
    
    for path in _videoURLs {
      if let _url = URL(string: path.absoluteString) {
        videoAssets.append(AVURLAsset(url: _url))
      }
    }
    
    if let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
      /// create a path to the video file
      completeMoviePath = URL(fileURLWithPath: documentsPath).appendingPathComponent("\(_fileName).m4v")
      
      if let completeMoviePath = completeMoviePath {
        if FileManager.default.fileExists(atPath: completeMoviePath.path) {
          do {
            /// delete an old duplicate file
            try FileManager.default.removeItem(at: completeMoviePath)
          } catch {
            failure(error)
          }
        }
      }
    } else {
      failure(VideoGeneratorError(error: .kFailedToFetchDirectory))
    }
    
    let composition = AVMutableComposition()
    
    if let completeMoviePath = completeMoviePath {
      
      /// add audio and video tracks to the composition
      if let videoTrack: AVMutableCompositionTrack = composition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid), let audioTrack: AVMutableCompositionTrack = composition.addMutableTrack(withMediaType: AVMediaType.audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        
        var insertTime = CMTime(seconds: 0, preferredTimescale: 1)
        
        /// for each URL add the video and audio tracks and their duration to the composition
        for sourceAsset in videoAssets {
          do {
            if let assetVideoTrack = sourceAsset.tracks(withMediaType: .video).first, let assetAudioTrack = sourceAsset.tracks(withMediaType: .audio).first {
              let frameRange = CMTimeRange(start: CMTime(seconds: 0, preferredTimescale: 1), duration: sourceAsset.duration)
              try videoTrack.insertTimeRange(frameRange, of: assetVideoTrack, at: insertTime)
              try audioTrack.insertTimeRange(frameRange, of: assetAudioTrack, at: insertTime)
              
              videoTrack.preferredTransform = assetVideoTrack.preferredTransform
            }
            
            insertTime = insertTime + sourceAsset.duration
          } catch {
            failure(error)
          }
        }
        
        /// try to start an export session and set the path and file type
        if let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) {
          exportSession.outputURL = completeMoviePath
          exportSession.outputFileType = AVFileType.mp4
          exportSession.shouldOptimizeForNetworkUse = true
          
          /// try to export the file and handle the status cases
          exportSession.exportAsynchronously(completionHandler: {
            switch exportSession.status {
            case .failed:
              if let _error = exportSession.error {
                failure(_error)
              }
              
            case .cancelled:
              if let _error = exportSession.error {
                failure(_error)
              }
              
            default:
              print("finished")
              success(completeMoviePath)
            }
          })
        } else {
          failure(VideoGeneratorError(error: .kFailedToStartAssetExportSession))
        }
      }
    }
  }
  
  // MARK: - Initialize/Livecycle methods
  
  public override init() {
    super.init()
  }
  
  /**
   setup method of the class
   
   - parameter _images:     The images from which a video will be generated
   - parameter _duration: The duration of the movie which will be generated
   */
  fileprivate func setup(withImages _images: [UIImage], andAudios _audios: [URL], andType _type: VideoGeneratorType) {
    images = []
    audioURLs = []
    audioDurations = []
    duration = 0.0
    
    /// guard against missing images or audio
    guard !_images.isEmpty else {
      return
    }
    
    guard !_audios.isEmpty else {
      return
    }
    
    type = _type
    audioURLs = _audios
    
    switch type! {
    case .single, .singleAudioMultipleImage:
      /// guard against multiple audios in single mode
      if _audios.count != 1 {
        if let _audio = _audios.first {
          audioURLs = [_audio]
        }
      }
    case .multiple:
      /// guard agains more then equal audio and images for multiple
      if _audios.count != _images.count {
        audioURLs = Array(_audios[..._images.count])
      }
    }
    
    /// populate the image array
    if type == .single {
      if let _image = _images.first {
        if let resizedImage = shouldOptimiseImageForVideo ? _image.resizeImageToVideoSize() : _image {
          images = [UIImage].init(repeating: resizedImage, count: 2)
        }
      }
    } else {
      for _image in _images {
        if let resizedImage = shouldOptimiseImageForVideo ? _image.resizeImageToVideoSize() : _image {
          images.append(resizedImage.scaleImageToSize(newSize: CGSize(width: 800, height: 800)))
        }
      }
    }
    
    var _duration: Double = 0
    
    var audioAssets: [AVURLAsset] = []
    for url in _audios {
      audioAssets.append(AVURLAsset(url: url, options: nil))
    }
    
    /// calculate the full video duration
    for audio in audioAssets {
      if let _maxLength = maxVideoLengthInSeconds {
        _duration += round(Double(CMTimeGetSeconds(audio.duration)))
        
        if _duration < _maxLength {
          audioDurations.append(round(Double(CMTimeGetSeconds(audio.duration))))
        } else {
          _duration -= round(Double(CMTimeGetSeconds(audio.duration)))
          let diff = _maxLength - _duration
          _duration = _maxLength
          audioDurations.append(diff)
        }
      } else {
        audioDurations.append(round(Double(CMTimeGetSeconds(audio.duration))))
        _duration += round(Double(CMTimeGetSeconds(audio.duration)))
      }
    }
    
    duration = max(_duration, Double(CMTime(seconds: minSingleVideoDuration, preferredTimescale: 1).seconds))
    
    if let _scaleWidth = scaleWidth {
      images = images.map({ $0.scaleImageToSize(newSize: CGSize(width: _scaleWidth, height: _scaleWidth)) })
    }
  }
  
  // MARK: - Override methods
  
  // MARK: - Private properties
  
  /// private property to store the images from which a video will be generated
  fileprivate var images: [UIImage] = []
  
  /// private property to store the different audio durations
  fileprivate var audioDurations: [Double] = []
  
  /// private property to store the audio URLs
  fileprivate var audioURLs: [URL] = []
  
  /// private property to store the duration of the generated video
  fileprivate var duration: Double! = 1.0
  
  /// private property to store a video asset writer (optional because the generation might fail)
  fileprivate var videoWriter: AVAssetWriter?
  
  /// private property video generation's type
  fileprivate var type: VideoGeneratorType?
  
  /// private property to store the minimum size for the video
  fileprivate var minSize = CGSize.zero
  
  /// private property to store the minimum duration for a single video
  fileprivate var minSingleVideoDuration: Double = 3.0
  
  // MARK: - Private methods
  
  /// Private method to generate a movie with the selected frame and the given audio
  ///
  /// - parameter audioUrl: the audio url
  /// - parameter videoUrl: the video url
  private func mergeAudio(withVideoURL videoUrl: URL, success: @escaping ((URL) -> Void), failure: @escaping ((Error) -> Void)) {
    /// create a mutable composition
    let mixComposition = AVMutableComposition()
    
    /// create a video asset from the url and get the video time range
    let videoAsset = AVURLAsset(url: videoUrl, options: nil)
    let videoTimeRange = CMTimeRange(start: kCMTimeZero, duration: videoAsset.duration)
    
    /// add a video track to the composition
    let videoComposition = mixComposition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)
    
    if let videoTrack = videoAsset.tracks(withMediaType: .video).first {
      do {
        /// try to insert the video time range into the composition
        try videoComposition?.insertTimeRange(videoTimeRange, of: videoTrack, at: kCMTimeZero)
      } catch {
        failure(error)
      }
      
      var duration = CMTime(seconds: 0, preferredTimescale: 1)
      
      /// add an audio track to the composition
      let audioCompositon = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      
      /// for all audio files add the audio track and duration to the existing audio composition
      for (index, audioUrl) in audioURLs.enumerated() {
        let audioDuration = CMTime(seconds: audioDurations[index], preferredTimescale: 1)
        
        let audioAsset = AVURLAsset(url: audioUrl)
        let audioTimeRange = CMTimeRange(start: kCMTimeZero, duration: maxVideoLengthInSeconds != nil ? audioDuration : audioAsset.duration)
        
        let shouldAddAudioTrack = maxVideoLengthInSeconds != nil ? audioDuration.seconds > 0 : true
        
        if shouldAddAudioTrack {
          if let audioTrack = audioAsset.tracks(withMediaType: .audio).first {
            do {
              try audioCompositon?.insertTimeRange(audioTimeRange, of: audioTrack, at: duration)
            } catch {
              failure(error)
            }
          }
        }
        
        duration = duration + (maxVideoLengthInSeconds != nil ? audioDuration : audioAsset.duration)
      }
      
      /// check if the documents folder is available
      if let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
        
        /// create a path to the video file
        let videoOutputURL = URL(fileURLWithPath: documentsPath).appendingPathComponent("\(fileName).m4v")
        
        do {
          /// delete an old duplicate file
          try FileManager.default.removeItem(at: videoOutputURL)
        } catch { }
        
        /// try to start an export session and set the path and file type
        if let exportSession = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality) {
          exportSession.outputURL = videoOutputURL
          exportSession.outputFileType = AVFileType.mp4
          exportSession.shouldOptimizeForNetworkUse = true
          
          /// try to export the file and handle the status cases
          exportSession.exportAsynchronously(completionHandler: {
            switch exportSession.status {
            case .failed:
              if let _error = exportSession.error {
                failure(_error)
              }
              
            case .cancelled:
              if let _error = exportSession.error {
                failure(_error)
              }
              
            default:
              let testMovieOutPutPath = URL(fileURLWithPath: documentsPath).appendingPathComponent("test.m4v")
              
              do {
                try FileManager.default.removeItem(at: testMovieOutPutPath)
              } catch { }
              
              success(videoOutputURL)
            }
          })
        } else {
          failure(VideoGeneratorError(error: .kFailedToStartAssetExportSession))
        }
      } else {
        failure(VideoGeneratorError(error: .kFailedToFetchDirectory))
      }
    } else {
      failure(VideoGeneratorError(error: .kFailedToReadVideoTrack))
    }
  }
  
  /**
   Private method to append pixels to a pixel buffer
   
   - parameter url:                The image which pixels will be appended to the pixel buffer
   - parameter pixelBufferAdaptor: The pixel buffer to which new pixels will be added
   - parameter presentationTime:   The duration of each frame of the video
   
   - returns: True or false depending on the action execution
   */
  private func appendPixelBufferForImage(_ image: UIImage, pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor, presentationTime: CMTime) -> Bool {
    
    /// at the beginning of the append the status is false
    var appendSucceeded = false
    
    /**
     *  The proccess of appending new pixels is put inside a autoreleasepool
     */
    autoreleasepool {
      
      // check posibilitty of creating a pixel buffer pool
      if let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool {
        
        let pixelBufferPointer = UnsafeMutablePointer<CVPixelBuffer?>.allocate(capacity: 1)
        let status: CVReturn = CVPixelBufferPoolCreatePixelBuffer(
          kCFAllocatorDefault,
          pixelBufferPool,
          pixelBufferPointer
        )
        
        /// check if the memory of the pixel buffer pointer can be accessed and the creation status is 0
        if let pixelBuffer = pixelBufferPointer.pointee, status == 0 {
          
          // if the condition is satisfied append the image pixels to the pixel buffer pool
          fillPixelBufferFromImage(image, pixelBuffer: pixelBuffer)
          
          // generate new append status
          appendSucceeded = pixelBufferAdaptor.append(
            pixelBuffer,
            withPresentationTime: presentationTime
          )
          
          /**
           *  Destroy the pixel buffer contains
           */
          pixelBufferPointer.deinitialize()
        } else {
          NSLog("error: Failed to allocate pixel buffer from pool")
        }
        
        /**
         Destroy the pixel buffer pointer from the memory
         */
        pixelBufferPointer.deallocate(capacity: 1)
      }
    }
    
    return appendSucceeded
  }
  
  /**
   Private method to append image pixels to a pixel buffer
   
   - parameter image:       The image which pixels will be appented
   - parameter pixelBuffer: The pixel buffer (as memory) to which the image pixels will be appended
   */
  private func fillPixelBufferFromImage(_ image: UIImage, pixelBuffer: CVPixelBuffer) {
    // lock the buffer memoty so no one can access it during manipulation
    CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
    
    // get the pixel data from the address in the memory
    let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer)
    
    // create a color scheme
    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    
    /// set the context size
    let contextSize = image.size
    
    // generate a context where the image will be drawn
    if let context = CGContext(data: pixelData, width: Int(contextSize.width), height: Int(contextSize.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
      
      var imageHeight = image.size.height
      var imageWidth = image.size.width
      
      if Int(imageHeight) > context.height {
        imageHeight = 16 * (CGFloat(context.height) / 16).rounded(.awayFromZero)
      } else if Int(imageWidth) > context.width {
        imageWidth = 16 * (CGFloat(context.width) / 16).rounded(.awayFromZero)
      }
      
      let center = type == .single ? CGPoint.zero : CGPoint(x: (minSize.width - imageWidth) / 2, y: (minSize.height - imageHeight) / 2)
      
      context.clear(CGRect(x: 0.0, y: 0.0, width: imageWidth, height: imageHeight))
      
      // set the context's background color
      context.setFillColor(type == .single ? UIColor.black.cgColor : videoBackgroundColor.cgColor)
      context.fill(CGRect(x: 0.0, y: 0.0, width: CGFloat(context.width), height: CGFloat(context.height)))
      
      context.concatenate(CGAffineTransform.identity)
      
      // draw the image in the context
      
      if let cgImage = image.cgImage {
        context.draw(cgImage, in: CGRect(x: center.x, y: center.y, width: imageWidth, height: imageHeight))
      }
      
      // unlock the buffer memory
      CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
    }
  }
}

/// Private class to represent a custom video generator error
private class VideoGeneratorError: NSObject, LocalizedError {
  
  public enum CustomError {
    case kFailedToStartAssetWriterError
    case kFailedToAppendPixelBufferError
    case kFailedToFetchDirectory
    case kFailedToStartAssetExportSession
    case kMissingVideoURLs
    case kFailedToReadProvidedClip
    case kUnsupportedVideoType
    case kFailedToStartReader
    case kFailedToReadVideoTrack
  }
  
  fileprivate var desc = ""
  fileprivate var error: CustomError
  fileprivate let kErrorDomain = "VideoGenerator"
  
  init(error: CustomError) {
    self.error = error
  }
  
  override var description: String {
    get {
      switch error {
      case .kFailedToStartAssetWriterError:
        return "\(kErrorDomain): AVAssetWriter failed to start writing"
      case .kFailedToAppendPixelBufferError:
        return "\(kErrorDomain): AVAssetWriterInputPixelBufferAdapter failed to append pixel buffer"
      case .kFailedToFetchDirectory:
        return "\(kErrorDomain): Can't find the Documents directory"
      case .kFailedToStartAssetExportSession:
        return "\(kErrorDomain): Can't begin an AVAssetExportSession"
      case .kMissingVideoURLs:
        return "\(kErrorDomain): Missing video paths"
      case .kFailedToReadProvidedClip:
        return "\(kErrorDomain): Couldn't read the supplied video's frames."
      case .kUnsupportedVideoType:
        return "\(kErrorDomain): Unsupported video type. Supported tyeps: .m4v, mp4, .mov"
      case .kFailedToStartReader:
        return "\(kErrorDomain): Failed to start reading video frames"
      case .kFailedToReadVideoTrack:
        return "\(kErrorDomain): Failed to read video track in asset"
      }
    }
  }
  
  var errorDescription: String? {
    get {
      return self.description
    }
  }
}

extension AVAsset {
  
  func videoOrientation() -> (orientation: UIInterfaceOrientation, device: AVCaptureDevice.Position) {
    var orientation: UIInterfaceOrientation = .unknown
    var device: AVCaptureDevice.Position = .unspecified
    
    let tracks :[AVAssetTrack] = self.tracks(withMediaType: .video)
    if let videoTrack = tracks.first {
      
      let t = videoTrack.preferredTransform
      
      if (t.a == 0 && t.b == 1.0 && t.d == 0) {
        orientation = .portrait
        
        if t.c == 1.0 {
          device = .front
        } else if t.c == -1.0 {
          device = .back
        }
      }
      else if (t.a == 0 && t.b == -1.0 && t.d == 0) {
        orientation = .portraitUpsideDown
        
        if t.c == -1.0 {
          device = .front
        } else if t.c == 1.0 {
          device = .back
        }
      }
      else if (t.a == 1.0 && t.b == 0 && t.c == 0) {
        orientation = .landscapeRight
        
        if t.d == -1.0 {
          device = .front
        } else if t.d == 1.0 {
          device = .back
        }
      }
      else if (t.a == -1.0 && t.b == 0 && t.c == 0) {
        orientation = .landscapeLeft
        
        if t.d == 1.0 {
          device = .front
        } else if t.d == -1.0 {
          device = .back
        }
      }
    }
    
    return (orientation, device)
  }
}
