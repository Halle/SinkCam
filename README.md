# SinkCam
## A CMIO Camera extension that is an output device for a sink stream from its container app

There are three major kinds of CMIO Camera Extensions: **software camera**, **creative camera**, and **output device**. [OffcutsCam](http://github.com/Halle/OffcutsCam) and [TechnicalDifficulties](http://github.com/Halle/TechnicalDifficulties) are examples of **software cameras** (all content generated inside the extension), [ArtFilm](http://github.com/Halle/ArtFilm) is an example of a **creative camera** (modifies a feed originating from another camera) and this is an example of an **output device**.

In an **output device**, the camera extension shows software or creative camera content (in this case, the same ascending and descending software white line content as OffcutsCam), but the extension has an input stream it can send to a camera output, so the CMIO Camera Extension can optionally output video that is streaming into it from the container app (in this case, the `AVCaptureSession` feed from the Continuity Camera or `.userPreferred` camera, i.e. a live camera feed which is not part of the CMIO Camera Extension).

I wanted to thank [Laurent Denoue](https://github.com/ldenoue) again for providing a [reference example](https://github.com/ldenoue/cameraextension) of this type of `CMIOExtensionStreamSource` and how it can be addressed by the app.

If you want to give it a try, it is necessary to change all references to my team ID and organization ID to yours (this occurs in a few places) or it will not be possible for you to codesign and install. This can only be run on a Ventura beta or later (at the time of this writing, there was no general release of Ventura yet), and if you want to use the **Continuity Camera**, you also need iOS 16 on your phone.

This is part 3.5 😅 of my three-part series on CMIO Camera Extensions on [The Offcuts](https://www.theoffcuts.org)
