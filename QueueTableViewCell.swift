//
//  QueueTableViewCell.swift
//  Snipgram
//
//  Created by Lexie Kemp on 8/25/18.
//  Copyright © 2018 Snip Inc. All rights reserved.
//

import UIKit
import CoreData
import Mixpanel
import AVFoundation
import Firebase
//table view cell for episodes in playlist, stats and audio urls are stored in queue home controller to keep consistency with reuse of cells
class QueueTableViewCell: UITableViewCell {

    @IBOutlet weak var podcastImage: CellButtonImageView!
    @IBOutlet weak var episodeTitleLabel: UILabel!
    @IBOutlet weak var episodeDurationLabel: UILabel!
    @IBOutlet weak var episodeDateLabel: UILabel!
    @IBOutlet weak var listensCountLabel: UILabel!
    @IBOutlet weak var showTitle: UILabel!
    
    @IBOutlet weak var shareButton: UIButton!
    @IBOutlet weak var likesButton: UIButton!
    @IBOutlet weak var commentButton: UIButton!
    @IBOutlet weak var playButton: UIButton!
    @IBOutlet weak var percentPlayedButton: UIButton!
    @IBOutlet weak var downloadButton: UIButton!

    var spinner: UIActivityIndicatorView = UIActivityIndicatorView()
    var spinnerView = UIView()
    var playSpinner: UIActivityIndicatorView = UIActivityIndicatorView()
    var playSpinnerView: UIView?
    let progressRing = CircularProgressIndicator()
    let pauseView = UIView()
    var queueItem: QueueItem?
    
    var player: AVQueuePlayer?
    var playerItem:AVPlayerItem?
    var showUrl: URL?
    var audioFileUrl: URL?
    var parentQueueVC: QueueHomeController?
    var timeObserver: Any?
    var queueSetUp = false
    var row: Int?
    
    var downloadProgress: Float = 0.0 {
        didSet {
            progressRing.goToProgress(downloadProgress)
        }
    }
    var likeCount = 0 {
        didSet {
            likesButton.setTitle(String(likeCount), for: .normal)
        }
    }
    var isLiked = false { //indicates whether or not the current user has already liked the item
        didSet {
            isLiked ? likesButton.setImage(UIImage(named: "likeIconPinkBig"), for: .normal) : likesButton.setImage(UIImage(named: "likeIconBig"), for: .normal)
        }
    }
    var isListenedTo = false {
        didSet {
            isListenedTo ? setListenedTo() : setUnlistenedTo()
        }
    }
    var isDownloaded = false {
        didSet {
            if isDownloaded {
                downloadButtonState = .downloaded
            }
            else if downloadButtonState != .downloading {
                downloadButtonState = .undownloaded
            }
        }
    }
    enum DownloadButtonStates {
        case undownloaded, downloading, downloaded
    }
    
    var downloadButtonState:DownloadButtonStates = .undownloaded {
        didSet{
            switch(downloadButtonState) {
            case .undownloaded:
                self.downloadButton.setImage(UIImage(named: "downloadIcon"), for: .normal)
                progressRing.removeFromSuperview()
                pauseView.removeFromSuperview()
            case .downloading:
                self.downloadButton.setImage(nil, for: .normal)
                print(downloadButton.frame)
                progressRing.drawTrack()
                self.downloadButton.addSubview(pauseView)
                self.downloadButton.addSubview(progressRing)
            case .downloaded:
                self.downloadButton.setImage(UIImage(named: "downloadedIcon"), for: .normal)
                progressRing.removeFromSuperview()
                pauseView.removeFromSuperview()
            }
        }
    }
    override func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
        
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        player = appDelegate.player
 
        podcastImage.makeRoundedCorners(cornerRadius: 5.0)
        setUpSpinnerView()
        setUpDownloadButton()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        
        let frame = contentView.frame
        let frameRect = UIEdgeInsetsInsetRect(frame, UIEdgeInsetsMake(2, 0, 2, 0))
        contentView.frame = frameRect
    }
    func setUpDownloadButton() {
        progressRing.frame.size = downloadButton.frame.size
        progressRing.frame.origin = CGPoint(x: 0, y: 0)
        progressRing.isUserInteractionEnabled = false
        
        let height = downloadButton.frame.size.height
        let width = downloadButton.frame.size.width
        let sideLength = min(height,width)/3
        pauseView.frame = CGRect(x: width/2 - sideLength/2, y: height/2 - sideLength/2 + 5, width: sideLength, height: sideLength)
        pauseView.backgroundColor = SnipColors.metaData
        pauseView.isUserInteractionEnabled = false
    }
    private func setUpSpinnerView() {
        //play button spinner
        playSpinnerView = UIView(frame: CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: self.playButton.frame.size.width, height: self.playButton.frame.size.height)))
        playSpinnerView!.backgroundColor = UIColor.clear
        playSpinner.hidesWhenStopped = true
        playSpinner.activityIndicatorViewStyle = .gray
        playSpinner.frame = CGRect(origin: CGPoint(x: playSpinnerView!.frame.size.width/2 - 10, y: playSpinnerView!.frame.size.height/2 - 10), size: CGSize(width: 20, height: 20))
        playSpinnerView!.addSubview(playSpinner)
        
        //download button spinner
        spinnerView = UIView(frame: CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: downloadButton.frame.size.width, height: downloadButton.frame.size.height)))
        spinnerView.backgroundColor = UIColor.white
        spinner.frame = CGRect(origin: CGPoint(x: 0,y :0), size: CGSize(width: downloadButton.frame.size.width, height: downloadButton.frame.size.height))
        spinner.hidesWhenStopped = true
        spinner.activityIndicatorViewStyle = .gray
        spinnerView.addSubview(spinner)
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }
    //update the UI with the information about the episode from the table view controller (QueueHomeController)
    func inflate(item: QueueItem, indexPath: IndexPath, parent: QueueHomeController) {
        queueItem = item
        parentQueueVC = parent
        episodeTitleLabel.text = item.episodeTitle
        episodeDurationLabel.text = QueueItem.getDurationLabel(duration: item.duration)
        episodeDateLabel.text = QueueItem.getReleaseDate(data: item.releaseData ?? "") ?? ""
        showUrl = item.showSmallArtUrl
        showTitle.text = item.showTitle
        if showUrl != nil {
            podcastImage.loadImage(urlString: showUrl!.absoluteString)
        }
        //keep track of which cell the button is for
        self.row = indexPath.row
        downloadButton.tag = indexPath.row
        likesButton.tag = indexPath.row
        commentButton.tag = indexPath.row
        playButton.tag = indexPath.row
        percentPlayedButton.tag = indexPath.row
        self.audioFileUrl = item.audioUrl
        updatePlayPauseButton()
        commentButton.addTarget(parent, action: #selector(parent.unavailableAlert), for: .touchUpInside)
    }
    //update the UI based on the user stats sent from QueueHomeController
    func updateStats(stats: CellUserStats) {
        listensCountLabel.text = String(stats.listenCount)
        likeCount = stats.likeCount
        commentButton.setTitle(String(stats.commentCount), for: .normal)
        isLiked = stats.isLiked
        isListenedTo = stats.isListened
        percentPlayedButton.setTitle("\(stats.percentListened)%", for: .normal)
        isDownloaded = stats.isDownloaded
    }
    func setListenedTo() {
        percentPlayedButton.setImage(UIImage(named: "playlistIconPink"), for: .normal)
    }
    func setUnlistenedTo() {
        percentPlayedButton.setImage(UIImage(named: "playlistIcon"), for: .normal)
    }
    @IBAction func downloadEpisode(_ sender: UIButton) {
        if downloadButtonState == .undownloaded {
            downloadButtonState = .downloading
            downloadProgress = 0.0
            if audioFileUrl != nil {
                parentQueueVC?.startDownload(audioUrl: audioFileUrl!, row: sender.tag) //queue home controller will manage progress
            }
        }
        else if downloadButtonState == .downloaded {
            if QueueDownloadManager.removeEpisode(audioUrl: audioFileUrl!.absoluteString), queueItem?.audioUrl != nil {
                downloadButtonState = .undownloaded
                isDownloaded = false
                audioFileUrl = queueItem!.audioUrl
                parentQueueVC?.undownloaded(row: sender.tag)
                let item = AVPlayerItem(url: queueItem!.audioUrl!)
                parentQueueVC?.setPlayerItem(row: sender.tag, item: item)
            }
            else {
                let title = episodeTitleLabel.text ?? ""
                let alert = UIAlertController(title: "Error undownloading \(title)", message: "Please try again later", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Okay", style: .default, handler: nil))
                parentQueueVC?.present(alert, animated: true)
            }
        }
        else if downloadButtonState == .downloading {
            if audioFileUrl != nil {
                parentQueueVC?.cancelDownload(audioUrl: audioFileUrl!)
            }
        }
    }
    @IBAction func likeClicked(_ sender: UIButton) {
        //update whether or not the user liked the video in Firebase
        if isLiked {
            likeCount -= 1
            isLiked = false
            if queueItem != nil {
                FirebaseDataManager.removeEpisodeLike(episode: Episode(queueItem: queueItem!))
            }
            self.parentQueueVC?.unLiked(row: sender.tag)
        }
        else {
            likeCount += 1
            isLiked = true
            if queueItem != nil {
                FirebaseDataManager.addEpisodeLike(episode: Episode(queueItem: queueItem!))
            }
            self.parentQueueVC?.liked(row: sender.tag)
            Mixpanel.mainInstance().track(event: "Episode Like")
            Analytics.logEvent("Episode Like", parameters: nil)
        }
    }
    @IBAction func commentClicked(_ sender: UIButton) {
        //show the episode details screen to post a comment
        parentQueueVC?.goToEpisodeDetails(row: sender.tag)
    }
    @IBAction func shareClicked(_ sender: UIButton) {
        if queueItem == nil || queueItem!.episodeId == nil { return }
        let episode = Episode(queueItem: queueItem!)
        //present a screen to share the episode with friends
        presentSharing(episode: episode, episodeId: queueItem!.episodeId!, sender: sender)
    }
    func presentSharing(episode: Episode, episodeId: String, sender: UIButton) {
        DynamicLinksManager.createEpisodeDynamicLink(episodeId: episodeId, showTitle: episode.showTitle, episodeTitle: episode.episodeTitle, showImageUrl: episode.showSmallArtUrl) { [weak self] url in
            if url != nil {
                let activityVC = UIActivityViewController(activityItems: [url as Any], applicationActivities: nil)
                activityVC.popoverPresentationController?.sourceView = sender
                self?.parentQueueVC?.present(activityVC, animated: true, completion: nil)
            }
        }
    }
    @IBAction func percentageClicked(_ sender: UIButton) {
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        let context = appDelegate.persistentContainer.viewContext
        //user marked the episode as unlistened
        if isListenedTo {
            isListenedTo = false
            self.parentQueueVC?.setUnlistened(row: sender.tag)
            if queueItem != nil, queueItem!.audioUrl != nil  {
                ListenedTo.removeSavedTime(audioUrl: queueItem!.audioUrl!.absoluteString, inManagedObjectContext: context) //remove the saved time in the episode from Core Data
                percentPlayedButton.setTitle("0%", for: .normal)
            }
        }
        //user marked the episode as listeneed
        else {
            isListenedTo = true
            self.parentQueueVC?.setListened(row: sender.tag)
            if queueItem != nil, queueItem!.audioUrl != nil  {
                ListenedTo.setListened(true, audioUrl: queueItem!.audioUrl!.absoluteString, inManagedObjectContext: context) //mark the episode as listened in Core Data
            }
        }
    }
    //Update the UI and notify the QueueHomeController when the user plays and episode
    @IBAction func playEpisode(_ sender: UIButton) {
        if player == nil { return }
        if row != nil {
            parentQueueVC?.playingRow = row!
        }
        if !isThisEpisodePlaying() { //chose a new episode
            if parentQueueVC != nil {
                ListenedTo.privatePopUp(viewController: parentQueueVC!) //notify the user the "listen privately mode" is turned off when a new episode is played
            }
            playSpinner.startAnimating()
            playButton.addSubview(playSpinnerView!)
            player?.pause()
            ListenedTo.updateTimeOfCurrent() //update the user's current time in the episode in Core Data
            if row != nil {
                parentQueueVC?.startedLoadingCell(row: row!) //notify QueueHomeController to update play button on visible cells
            }
            NotificationCenter.default.post(Notification(name: .loadingPlayer, object: nil, userInfo: nil)) //notify the bottom bar player that and episode is loading so that it will update the UI with a spinner
            setupCurrentEpisodeForPlay() //update the app's player with the new episode information
        }
        //update play button
        else if player?.rate == 0.0 { //finished loading player
            playSpinner.stopAnimating()
            playSpinnerView?.removeFromSuperview() //remove spinner
            BasicPlayerControls.togglePlayPause(player: player!)
            updatePlayPauseButton()
            NotificationCenter.default.post(Notification(name: .stopLoadingPlayer, object: nil, userInfo: nil))
            if timeObserver == nil {
                configureTimePeriodObserver()
            }
        }
        else {
            BasicPlayerControls.togglePlayPause(player: player!)
            updatePlayPauseButton()
        }
    }
    func setPlayButtonPlay() {
        playButton.setImage(UIImage(named: "playlistPlayButton"), for: .normal)
        playSpinner.stopAnimating()
        playSpinnerView?.removeFromSuperview()
    }
    private func setUpQueue(currEpisodeRow: Int) {
        if let queueItems = parentQueueVC?.getQueueItems() {
            player?.removeAllItems()
            for i in Int(currEpisodeRow)..<queueItems.count {
                var episode = AVPlayerItem(url: queueItems[i].audioUrl!)
                if let downloadedUrl = QueueDownloadManager.retrieveEpisode(audioUrl: queueItems[i].audioUrl!.absoluteString) {
                    episode = AVPlayerItem(url: downloadedUrl)
                }
                print("audio url is \(queueItems[i].audioUrl!.absoluteString)")
                player?.insert(episode, after: nil)
            }
            player?.actionAtItemEnd = .pause
            queueSetUp = true
        }
    }
    private func isThisEpisodePlaying() -> Bool {
        if let currentItem = player?.currentItem?.asset as? AVURLAsset {
            let fileName = currentItem.url.lastPathComponent
            let cellUrl = audioFileUrl?.lastPathComponent
            if cellUrl == fileName {
                return true
            }
        }
        return false
    }
    
    func setupCurrentEpisodeForPlay(){
        if row != nil, let newItem = parentQueueVC?.getPlayerForCell(row: row!) {
            player?.replaceCurrentItem(with: newItem)
            print("new url is \((newItem.asset as! AVURLAsset).url.lastPathComponent)")
        }
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        CurrentlyPlayingInfo.deleteAll(appDelegate: appDelegate)
        let episode = Episode(queueItem: queueItem!)
        CurrentlyPlayingInfo.setCurrentlyPlaying(episode: episode, appDelegate: appDelegate)
        if let savedTime = ListenedTo.savedTime(audioUrl: episode.audioUrl.absoluteString, inManagedObjectContext: appDelegate.persistentContainer.viewContext) {
            player?.seek(to: savedTime)
        }
        BasicPlayerControls.togglePlayPause(player: player!)
        //track number of episodes played in Mixplanel
        Mixpanel.mainInstance().track(event: "Episode_Played")
        addPlayerObservers() //observe to see when episode is finished loading
    }
    
    func addPlayerObservers() {
        parentQueueVC?.addPlayerObserver()
        configureTimePeriodObserver()
    }
    
    private func configureTimePeriodObserver() {
        if self.timeObserver != nil {
            player?.removeTimeObserver(self.timeObserver!)
        }
        self.timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTimeMakeWithSeconds(1, 1), queue: DispatchQueue.main) {
            [weak self] time in
            guard let strongSelf = self else { return }
            if (strongSelf.player!.currentItem?.status == .readyToPlay && strongSelf.player?.currentItem?.isPlaybackLikelyToKeepUp ?? false) ||  strongSelf.player?.rate != 0.0 { //episode is finished loading
                strongSelf.playSpinner.stopAnimating()
                strongSelf.playSpinnerView?.removeFromSuperview()
                strongSelf.parentQueueVC?.playerIsLoading = false
            }
            strongSelf.updatePlayPauseButton()
        }
    }
    //update whether the play put is a spinner (loading) or play or pause
    func updatePlayPauseButton(){
        if parentQueueVC == nil || row == nil { return }
        if parentQueueVC!.playingRow == row {
            if player?.rate != 0.0 {
                playButton.setImage(UIImage(named: "playlistPauseButton"), for: .normal)
                playSpinner.stopAnimating()
                playSpinnerView?.removeFromSuperview()
            }
            else if parentQueueVC!.playerIsLoading {
                if playSpinner.isAnimating {
                    playButton.setImage(UIImage(named: "playlistWhiteCircle"), for: .normal)
                }
                else if playSpinnerView != nil {
                    playButton.setImage(UIImage(named: "playlistWhiteCircle"), for: .normal)
                    playSpinner.startAnimating()
                    playButton.addSubview(playSpinnerView!)
                }
            }
            else {
                playButton!.setImage(UIImage(named: "playlistPlayButton"), for: .normal)
                playSpinner.stopAnimating()
                playSpinnerView?.removeFromSuperview()
            }
        }
        else {
            playButton!.setImage(UIImage(named: "playlistPlayButton"), for: .normal)
            playSpinner.stopAnimating()
            playSpinnerView?.removeFromSuperview()
        }
    }
}
