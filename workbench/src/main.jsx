// Workbench entry point. Mounts the SolidJS app; the engine boots inside <App />.
import { render } from "solid-js/web";
import App from "./App.jsx";
import "./styles.css";

render(() => <App />, document.getElementById("app"));
