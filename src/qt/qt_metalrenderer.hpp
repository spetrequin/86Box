/*
 * 86Box    Metal renderer (Apple only).
 *
 *          A QWindow-backed RendererCommon, embedded via createWindowContainer
 *          exactly like the OpenGL and Vulkan window renderers. It owns a
 *          CAMetalLayer on its native NSView and forwards 86Box's CPU blit
 *          buffers to MetalPresenter. Kept free of Objective-C so it can be
 *          included by plain C++ (qt_rendererstack.cpp); all Metal lives in
 *          qt_metalrenderer.mm / metal_presenter.mm.
 */
#ifndef QT_METALRENDERER_HPP
#define QT_METALRENDERER_HPP

#include <QWindow>

#include <array>
#include <atomic>
#include <memory>
#include <tuple>
#include <vector>

#include "qt_renderercommon.hpp"

class MetalPresenter;

class MetalRenderer : public QWindow, public RendererCommon {
    Q_OBJECT
public:
    explicit MetalRenderer(QWidget *parent);
    ~MetalRenderer() override;

    void finalize() override final;

    bool     hasOptions() const override;
    QDialog *getOptions(QWidget *parent) override;

public slots:
    void onBlit(int buf_idx, int x, int y, int w, int h);

signals:
    void rendererInitialized();
    void errorInitializing();

protected:
    std::vector<std::tuple<uint8_t *, std::atomic_flag *>> getBuffers() override;
    uint32_t                                               getBytesPerRow() override;

    void exposeEvent(QExposeEvent *event) override;
    void resizeEvent(QResizeEvent *event) override;
    bool event(QEvent *event) override;

private:
    void initialize();
    void updateDrawableSize();

    std::unique_ptr<MetalPresenter> presenter;
    std::array<std::unique_ptr<uint8_t[]>, 2> imagebufs;
    bool isInitialized = false;
    bool initFailed    = false;
};

#endif // QT_METALRENDERER_HPP
